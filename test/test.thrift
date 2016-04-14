namespace erl rpc

struct Weapon {
    1: required string name
    2: required i16 slot_pos
    3: optional i16 ammo
}

struct Powerup {
    1: required string name
    2: optional i16 level
    3: optional i16 time_left
}

enum Direction {
    NEXT = 1
    PREV = 0
}

exception Failure {
    1: required string code
    2: optional string reason
}

service Weapons {
    Weapon switch_weapon(
        1: Weapon current_weapon
        2: Direction direction
        3: i16 shift
        4: binary data
    ) throws (1: Failure error)
    Weapon get_weapon(
        1: string name
        2: binary data
    ) throws (1: Failure error)
}

service Powerups {
    Powerup get_powerup(
        1: string name
        2: binary data
    ) throws(1: Failure error)
}
