-ifndef(_woody_test_types_included).
-define(_woody_test_types_included, yeah).


-define(WOODY_TEST_DIRECTION_NEXT, 1).
-define(WOODY_TEST_DIRECTION_PREV, 0).

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

%% struct 'weapon_failure'

-record('weapon_failure', {
    'exception_name' = <<"weapon failure">> :: binary(),
    'code' :: binary(),
    'reason' :: binary()
}).

-type 'weapon_failure'() :: #'weapon_failure'{}.

%% struct 'powerup_failure'

-record('powerup_failure', {
    'exception_name' = <<"powerup failure">> :: binary(),
    'code' :: binary(),
    'reason' :: binary()
}).

-type 'powerup_failure'() :: #'powerup_failure'{}.

-endif.
