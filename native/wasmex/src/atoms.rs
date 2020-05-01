rustler::rustler_atoms! {
    atom ok;
    atom error;
    atom __nil__ = "nil";

    // memory types
    atom uint8;
    atom int8;
    atom uint16;
    atom int16;
    atom uint32;
    atom int32;

    // imported function param/return types
    atom i32;
    atom i64;
    atom f32;
    atom f64;
    atom v128;

    // import objects
    atom __fn__ = "fn";
    atom params;
    atom results;

    // calls to erlang processes
    atom returned_function_call;
    atom invoke_callback;
}
