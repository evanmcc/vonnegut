-define(CLIENT_ID, "vg_client").
-define(MAX_REQUEST_ID, 2147483647).

-define(MAGIC, 1).
-define(API_VERSION, 1).

-define(PRODUCE_REQUEST, 0).
-define(FETCH_REQUEST, 1).
-define(METADATA_REQUEST, 3).

-define(COMPRESS_NONE, 0).
-define(COMPRESS_GZIP, 1).
-define(COMPRESS_SNAPPY, 2).
-define(COMPRESS_LZ4, 3).

-define(COMPRESSION_MASK, 7).
-define(COMPRESSION(Attr), ?COMPRESSION_MASK band Attr).

%% non-kafka extension
-define(TOPICS_REQUEST, 1000).
-define(FETCH2_REQUEST, 1001).
-define(ENSURE_REQUEST, 1002).
-define(REPLICATE_REQUEST, 1003).

-define(UNKNOWN_ERROR, -1).
-define(NO_ERROR, 0).
-define(UNKNOWN_TOPIC_OR_PARTITION, 3).
-define(NOT_LEADER_ERROR, 6).  % reusing this to mean topic map has chaned
-define(TIMEOUT_ERROR, 7).

%% non-kafka extensions
-define(FETCH_DISALLOWED_ERROR, 129).
-define(PRODUCE_DISALLOWED_ERROR, 131).
-define(WRITE_REPAIR, 133).

-define(SEGMENTS_TABLE, logs_segments_table).
-define(WATERMARK_TABLE, high_watermarks_table).
-define(CHAINS_TABLE, chains_table).

-define(topic_map, topic_map).

-record(chain, {
          name  :: binary() | atom(),
          nodes :: [atom()] | undefined,
          topics_start :: binary() | start_space | undefined, % undef required because there's no way
          topics_end :: binary() | end_space | undefined,     % to encode these in metadata :\
          head  :: {inet:ip_address() | inet:hostname(), inet:port_number()},
          tail  :: {inet:ip_address() | inet:hostname(), inet:port_number()}
         }).
-type chain() :: #chain{}.
