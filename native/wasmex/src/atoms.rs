rustler::atoms! {
    ok,
    error,
    raise,
    __nil__ = "nil",

    // memory types
    uint8,
    int8,
    uint16,
    int16,
    uint32,
    int32,

    // imported function param/return types
    i32,
    i64,
    f32,
    f64,
    v128,
    reference,
    extern_ref,
    func_ref,
    caller,

    // import objects
    __fn__ = "fn",
    global,
    memory,
    table,
    tag,
    params,
    results,
    maximum,
    minimum,
    shared,
    memory64,
    mutability,
    __const__ = "const",
    var,
    __type__ = "type",

    // calls to erlang processes
    returned_function_call,
    invoke_callback,

    // option
    some,
    none,

    // engine config - cranelift_opt_level
    speed,
    speed_and_size,
    
    nil,
}
