-ifndef(_rpc_test_types_included).
-define(_rpc_test_types_included, yeah).


-define(RPC_TEST_DIRECTION_NEXT, 1).
-define(RPC_TEST_DIRECTION_PREV, 0).

%% struct 'weapon'

-record('weapon', {
    'name' :: binary(),
    'slot_pos' :: integer(),
    'ammo' :: integer()
}).

-type 'weapon'() :: #'weapon'{}.

%% struct 'powerup'

-record('powerup', {
    'name' :: binary(),
    'level' :: integer(),
    'time_left' :: integer()
}).

-type 'powerup'() :: #'powerup'{}.

%% struct 'failure'

-record('failure', {
    'code' :: binary(),
    'reason' :: binary()
}).

-type 'failure'() :: #'failure'{}.

-endif.
