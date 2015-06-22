%%%
%%%   Copyright (c) 2014, 2015, Klarna AB
%%%
%%%   Licensed under the Apache License, Version 2.0 (the "License");
%%%   you may not use this file except in compliance with the License.
%%%   You may obtain a copy of the License at
%%%
%%%       http://www.apache.org/licenses/LICENSE-2.0
%%%
%%%   Unless required by applicable law or agreed to in writing, software
%%%   distributed under the License is distributed on an "AS IS" BASIS,
%%%   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%%   See the License for the specific language governing permissions and
%%%   limitations under the License.
%%%

%%%=============================================================================
%%% @doc A kafka protocol implementation.
%%%      [https://cwiki.apache.org/confluence/display/KAFKA/
%%%       A+Guide+To+The+Kafka+Protocol].
%%% @copyright 2014, 2015 Klarna AB
%%% @end
%%%=============================================================================

-module(brod_kafka).

%% API
-export([ api_key/1
        , parse_stream/2
        , encode/1
        , encode/2
        , decode/2
        , is_error/1
        ]).

%%%_* Includes -----------------------------------------------------------------
-include("brod_int.hrl").
-include("brod_kafka.hrl").

%%%_* API ----------------------------------------------------------------------
%% @doc Parse binary stream of kafka responses.
%%      Returns list of {CorrId, Response} tuples and remaining binary.
%%      CorrIdDict: dict(CorrId -> ApiKey)
parse_stream(Bin, CorrIdDict) ->
  parse_stream(Bin, [], CorrIdDict).

parse_stream(<<Size:32/integer,
               Bin0:Size/binary,
               Tail/binary>>, Acc, CorrIdDict0) ->
  <<CorrId:32/integer, Bin/binary>> = Bin0,
  ApiKey = dict:fetch(CorrId, CorrIdDict0),
  Response = decode(ApiKey, Bin),
  CorrIdDict = dict:erase(CorrId, CorrIdDict0),
  parse_stream(Tail, [{CorrId, Response} | Acc], CorrIdDict);
parse_stream(Bin, Acc, CorrIdDict) ->
  {Bin, Acc, CorrIdDict}.

encode(CorrId, Request) ->
  Header = header(api_key(Request), CorrId),
  Body = encode(Request),
  Bin = <<Header/binary, Body/binary>>,
  Size = byte_size(Bin),
  <<Size:32/integer, Bin/binary>>.

api_key(#metadata_request{}) -> ?API_KEY_METADATA;
api_key(#produce_request{})  -> ?API_KEY_PRODUCE;
api_key(#offset_request{})   -> ?API_KEY_OFFSET;
api_key(#fetch_request{})    -> ?API_KEY_FETCH.

decode(?API_KEY_METADATA, Bin) -> metadata_response(Bin);
decode(?API_KEY_PRODUCE, Bin)  -> produce_response(Bin);
decode(?API_KEY_OFFSET, Bin)   -> offset_response(Bin);
decode(?API_KEY_FETCH, Bin)    -> fetch_response(Bin).

is_error(no_error)             -> false;
is_error(X) when is_integer(X) -> is_error(error_code_to_atom(X));
is_error(X) when is_atom(X)    -> true.

error_code_to_atom(0)  -> no_error;
error_code_to_atom(-1) -> unexpected_server_error;
error_code_to_atom(1)  -> offset_out_of_range;
error_code_to_atom(2)  -> invalid_message;
error_code_to_atom(3)  -> unknown_topic_or_partition;
error_code_to_atom(4)  -> invalid_message_size;
error_code_to_atom(5)  -> leader_not_available;
error_code_to_atom(6)  -> not_leader_for_partition;
error_code_to_atom(7)  -> request_timed_out;
error_code_to_atom(8)  -> broker_not_available;
error_code_to_atom(9)  -> replica_not_available;
error_code_to_atom(10) -> message_size_too_large;
error_code_to_atom(11) -> stale_controller_epoch_code;
error_code_to_atom(12) -> offset_metadata_too_large;
error_code_to_atom(14) -> offsets_load_in_progress;
error_code_to_atom(15) -> consumer_coordinator_not_available;
error_code_to_atom(16) -> not_coordinator_for_consumer;
error_code_to_atom(X) when X > 0 andalso X < 256 ->
  list_to_atom("error_code_" ++ integer_to_list(X));
error_code_to_atom(_X) ->
  unknown_error_code.

%%%_* Internal functions -------------------------------------------------------
header(ApiKey, CorrId) ->
  <<ApiKey:16/integer,
    ?API_VERSION:16/integer,
    CorrId:32/integer,
    ?CLIENT_ID_SIZE:16/integer,
    ?CLIENT_ID/binary>>.

encode(#metadata_request{} = Request) ->
  metadata_request_body(Request);
encode(#produce_request{} = Request)  ->
  produce_request_body(Request);
encode(#offset_request{} = Request)  ->
  offset_request_body(Request);
encode(#fetch_request{} = Request)  ->
  fetch_request_body(Request).

%%%_* metadata -----------------------------------------------------------------
metadata_request_body(#metadata_request{topics = []}) ->
  <<0:32/integer, -1:16/signed-integer>>;
metadata_request_body(#metadata_request{topics = Topics}) ->
  Length = erlang:length(Topics),
  F = fun(Topic, Acc) ->
          Size = kafka_size(Topic),
          <<Size:16/signed-integer, Topic/binary, Acc/binary>>
      end,
  Bin = lists:foldl(F, <<>>, Topics),
  <<Length:32/integer, Bin/binary>>.

metadata_response(Bin0) ->
  {Brokers, Bin} = parse_array(Bin0, fun parse_broker_metadata/1),
  {Topics, _} = parse_array(Bin, fun parse_topic_metadata/1),
  #metadata_response{brokers = Brokers, topics = Topics}.

parse_broker_metadata(<<NodeID:32/integer,
                        HostSize:16/integer,
                        Host:HostSize/binary,
                        Port:32/integer,
                        Bin/binary>>) ->
  Broker = #broker_metadata{ node_id = NodeID
                           , host = binary_to_list(Host)
                           , port = Port},
  {Broker, Bin}.

parse_topic_metadata(<<ErrorCode:16/signed-integer,
                       Size:16/integer,
                       Name:Size/binary,
                       Bin0/binary>>) ->
  {Partitions, Bin} = parse_array(Bin0, fun parse_partition_metadata/1),
  Topic = #topic_metadata{ error_code = error_code_to_atom(ErrorCode)
                         , name = binary:copy(Name)
                         , partitions = Partitions},
  {Topic, Bin}.

%% isrs = "in sync replicas"
parse_partition_metadata(<<ErrorCode:16/signed-integer,
                           Id:32/integer,
                           LeaderId:32/signed-integer,
                           Bin0/binary>>) ->
  {Replicas, Bin1} = parse_array(Bin0, fun parse_int32/1),
  {Isrs, Bin} = parse_array(Bin1, fun parse_int32/1),
  Partition = #partition_metadata{ error_code = error_code_to_atom(ErrorCode)
                                 , id = Id
                                 , leader_id = LeaderId
                                 , replicas = Replicas
                                 , isrs = Isrs},
  {Partition, Bin}.

%%%_* produce ------------------------------------------------------------------
produce_request_body(#produce_request{} = Produce) ->
  Acks = Produce#produce_request.acks,
  Timeout = Produce#produce_request.timeout,
  Topics = Produce#produce_request.data,
  TopicsCount = erlang:length(Topics),
  Head = <<Acks:16/signed-integer,
           Timeout:32/integer,
           TopicsCount:32/integer>>,
  encode_topics(Topics, Head).

encode_topics([], Acc) ->
  Acc;
encode_topics([{Topic, PartitionsDict} | T], Acc0) ->
  Size = erlang:size(Topic),
  Partitions = dict:to_list(PartitionsDict),
  PartitionsCount = erlang:length(Partitions),
  Acc1 = <<Acc0/binary, Size:16/integer, Topic/binary,
           PartitionsCount:32/integer>>,
  Acc = encode_partitions(Partitions, Acc1),
  encode_topics(T, Acc).

encode_partitions([], Acc) ->
  Acc;
encode_partitions([{Id, Messages} | T], Acc0) ->
  MessageSet = encode_message_set(Messages),
  MessageSetSize = erlang:size(MessageSet),
  Acc = <<Acc0/binary,
          Id:32/integer,
          MessageSetSize:32/integer,
          MessageSet/binary>>,
  encode_partitions(T, Acc).

encode_message_set(Messages) ->
  encode_message_set(Messages, <<>>).

encode_message_set([], Acc) ->
  Acc;
encode_message_set([Msg | Messages], Acc0) ->
  MsgBin = encode_message(Msg),
  Size = size(MsgBin),
  %% 0 is for offset which is unknown until message is handled by
  %% server, we can put any number here actually
  Acc = <<Acc0/binary, 0:64/integer, Size:32/integer, MsgBin/binary>>,
  encode_message_set(Messages, Acc).

encode_message({Key, Value}) ->
  KeySize = kafka_size(Key),
  ValSize = kafka_size(Value),
  Message = <<?MAGIC_BYTE:8/integer,
              ?COMPRESS_NONE:8/integer,
              KeySize:32/signed-integer,
              Key/binary,
              ValSize:32/signed-integer,
              Value/binary>>,
  Crc32 = erlang:crc32(Message),
  <<Crc32:32/integer, Message/binary>>.

produce_response(Bin) ->
  {Topics, _} = parse_array(Bin, fun parse_produce_topic/1),
  #produce_response{topics = Topics}.

parse_produce_topic(<<Size:16/integer, Name:Size/binary, Bin0/binary>>) ->
  {Offsets, Bin} = parse_array(Bin0, fun parse_produce_offset/1),
  {#produce_topic{topic = binary:copy(Name), offsets = Offsets}, Bin}.

parse_produce_offset(<<Partition:32/integer,
                       ErrorCode:16/signed-integer,
                       Offset:64/integer,
                       Bin/binary>>) ->
  Res = #produce_offset{ partition = Partition
                       , error_code = error_code_to_atom(ErrorCode)
                       , offset = Offset},
  {Res, Bin}.

%%%_* offset -------------------------------------------------------------------
offset_request_body(#offset_request{} = Offset) ->
  Topic = Offset#offset_request.topic,
  Partition = Offset#offset_request.partition,
  Time = Offset#offset_request.time,
  MaxNumberOfOffsets = Offset#offset_request.max_n_offsets,
  TopicSize = erlang:size(Topic),
  PartitionsCount = 1,
  TopicsCount = 1,
  <<?REPLICA_ID:32/signed-integer,
    TopicsCount:32/integer,
    TopicSize:16/integer,
    Topic/binary,
    PartitionsCount:32/integer,
    Partition:32/integer,
    Time:64/signed-integer,
    MaxNumberOfOffsets:32/integer>>.

offset_response(Bin) ->
  {Topics, _} = parse_array(Bin, fun parse_offset_topic/1),
  #offset_response{topics = Topics}.

parse_offset_topic(<<Size:16/integer, Name:Size/binary, Bin0/binary>>) ->
  {Partitions, Bin} = parse_array(Bin0, fun parse_partition_offsets/1),
  {#offset_topic{topic = binary:copy(Name), partitions = Partitions}, Bin}.

parse_partition_offsets(<<Partition:32/integer,
                          ErrorCode:16/signed-integer,
                          Bin0/binary>>) ->
  {Offsets, Bin} = parse_array(Bin0, fun parse_int64/1),
  Res = #partition_offsets{ partition = Partition
                          , error_code = error_code_to_atom(ErrorCode)
                          , offsets = Offsets},
  {Res, Bin}.

%%%_* fetch --------------------------------------------------------------------
fetch_request_body(#fetch_request{} = Fetch) ->
  #fetch_request{ max_wait_time = MaxWaitTime
                , min_bytes     = MinBytes
                , topic         = Topic
                , partition     = Partition
                , offset        = Offset
                , max_bytes     = MaxBytes} = Fetch,
  PartitionsCount = 1,
  TopicsCount = 1,
  TopicSize = erlang:size(Topic),
  <<?REPLICA_ID:32/signed-integer,
    MaxWaitTime:32/integer,
    MinBytes:32/integer,
    TopicsCount:32/integer,
    TopicSize:16/integer,
    Topic/binary,
    PartitionsCount:32/integer,
    Partition:32/integer,
    Offset:64/integer,
    MaxBytes:32/integer>>.

fetch_response(Bin) ->
  {Topics, _} = parse_array(Bin, fun parse_topic_fetch_data/1),
  #fetch_response{topics = Topics}.

parse_topic_fetch_data(<<Size:16/integer, Name:Size/binary, Bin0/binary>>) ->
  {Partitions, Bin} = parse_array(Bin0, fun parse_partition_messages/1),
  {#topic_fetch_data{topic = binary:copy(Name), partitions = Partitions}, Bin}.

parse_partition_messages(<<Partition:32/integer,
                           ErrorCode:16/signed-integer,
                           HighWmOffset:64/integer,
                           MessageSetSize:32/integer,
                           MessageSetBin:MessageSetSize/binary,
                           Bin/binary>>) ->
  {LastOffset, Messages} = parse_message_set(MessageSetBin),
  Res = #partition_messages{ partition = Partition
                           , error_code = error_code_to_atom(ErrorCode)
                           , high_wm_offset = HighWmOffset
                           , last_offset = LastOffset
                           , messages = Messages},
  {Res, Bin}.

parse_message_set(Bin) ->
  parse_message_set(Bin, []).

parse_message_set(<<>>, []) ->
  {0, []};
parse_message_set(<<>>, [Msg | _] = Acc) ->
  {Msg#message.offset, lists:reverse(Acc)};
parse_message_set(<<Offset:64/integer,
                    MessageSize:32/integer,
                    MessageBin:MessageSize/binary,
                    Bin/binary>>, Acc) ->
  <<Crc:32/integer,
    MagicByte:8/integer,
    Attributes:8/integer,
    KeySize:32/signed-integer,
    KV/binary>> = MessageBin,
  {Key, ValueBin} = parse_bytes(KeySize, KV),
  <<ValueSize:32/signed-integer, Value0/binary>> = ValueBin,
  {Value, <<>>} = parse_bytes(ValueSize, Value0),
  Msg = #message{ offset     = Offset
                , crc        = Crc
                , magic_byte = MagicByte
                , attributes = Attributes
                , key        = Key
                , value      = Value},
  parse_message_set(Bin, [Msg | Acc]);
parse_message_set(_Bin, [Msg | _] = Acc) ->
  %% the last message in response was sent only partially, dropping
  {Msg#message.offset, lists:reverse(Acc)};
parse_message_set(_Bin, []) ->
  %% The only case when I managed to get there is when max_bytes option
  %% is too small to for a whole message.
  %% For some reason kafka does not report error.
  throw("max_bytes option is too small").

parse_array(<<Length:32/integer, Bin/binary>>, Fun) ->
  parse_array(Length, Bin, [], Fun).

parse_array(0, Bin, Acc, _Fun) ->
  {Acc, Bin};
parse_array(Length, Bin0, Acc, Fun) ->
  {Item, Bin} = Fun(Bin0),
  parse_array(Length - 1, Bin, [Item | Acc], Fun).

parse_int32(<<X:32/integer, Bin/binary>>) -> {X, Bin}.

parse_int64(<<X:64/integer, Bin/binary>>) -> {X, Bin}.

kafka_size(<<"">>) -> -1;
kafka_size(Bin)    -> size(Bin).

parse_bytes(-1, Bin) ->
  {<<>>, Bin};
parse_bytes(Size, Bin0) ->
  <<Bytes:Size/binary, Bin/binary>> = Bin0,
  {binary:copy(Bytes), Bin}.

%% Tests -----------------------------------------------------------------------
-include_lib("eunit/include/eunit.hrl").

-ifdef(TEST).

parse_array_test() ->
  F = fun(<<Size:32/integer, X:Size/binary, Bin/binary>>) ->
          {binary_to_list(X), Bin}
      end,
  ?assertMatch({["BARR", "FOO"], <<>>},
               parse_array(<<2:32/integer, 3:32/integer, "FOO",
                                           4:32/integer, "BARR">>, F)),
  ?assertMatch({["FOO"], <<4:32/integer, "BARR">>},
               parse_array(<<1:32/integer, 3:32/integer, "FOO",
                                           4:32/integer, "BARR">>, F)),
  ?assertMatch({[], <<>>}, parse_array(<<0:32/integer>>, F)),
  ?assertError(function_clause, parse_array(<<-1:32/integer>>, F)),
  ?assertError(function_clause, parse_array(<<1:32/integer>>, F)),
  ok.

parse_int32_test() ->
  ?assertMatch({0, <<"123">>}, parse_int32(<<0:32/integer, "123">>)),
  ?assertMatch({0, <<"">>}, parse_int32(<<0:32/integer>>)),
  ?assertError(function_clause, parse_int32(<<0:16/integer>>)),
  ok.

parse_int64_test() ->
  ?assertMatch({0, <<"123">>}, parse_int64(<<0:64/integer, "123">>)),
  ?assertMatch({0, <<"">>}, parse_int64(<<0:64/integer>>)),
  ?assertError(function_clause, parse_int64(<<0:32/integer>>)),
  ok.

parse_bytes_test() ->
  ?assertMatch({<<"1234">>, <<"5678">>}, parse_bytes(4, <<"12345678">>)),
  ?assertMatch({<<"1234">>, <<"">>}, parse_bytes(4, <<"1234">>)),
  ?assertMatch({<<"">>, <<"1234">>}, parse_bytes(-1, <<"1234">>)),
  ?assertError({badmatch, <<"123">>}, parse_bytes(4, <<"123">>)),
  ok.

-endif. % TEST

%%% Local Variables:
%%% erlang-indent-level: 2
%%% End:
