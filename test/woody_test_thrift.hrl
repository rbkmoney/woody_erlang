-ifndef(woody_test_thrift_included__).
-define(woody_test_thrift_included__, yeah).



%% struct 'weapon'
-record('weapon', {
    'name' :: binary(),
    'slot_pos' :: integer(),
    'ammo' :: integer()
}).

%% struct 'powerup'
-record('powerup', {
    'name' :: binary(),
    'level' :: integer(),
    'time_left' :: integer()
}).

%% exception 'weapon_failure'
-record('weapon_failure', {
    'exception_name' = <<"weapon failure">> :: binary(),
    'code' :: binary(),
    'reason' :: binary()
}).

%% exception 'powerup_failure'
-record('powerup_failure', {
    'exception_name' = <<"powerup failure">> :: binary(),
    'code' :: binary(),
    'reason' :: binary()
}).

-endif.
