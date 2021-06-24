rustler::atoms! {
    ok,
    error,
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

    // import objects
    __fn__ = "fn",
    params,
    results,
    
    // wasi import options
    resource,

    // callback context
    memory,

    // calls to erlang processes
    returned_function_call,
    invoke_callback,
}
