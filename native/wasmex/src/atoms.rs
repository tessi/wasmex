rustler::rustler_atoms! {
    atom ok;
    atom error;
    atom success;
    atom __nil__ = "nil";

    atom uint8;
    atom int8;
    atom uint16;
    atom int16;
    atom uint32;
    atom int32;

    atom i32;
    atom i64;
    atom f32;
    atom f64;
    atom v128;

    atom __fn__ = "fn";

    atom params;
    atom results;

    atom returned_function_call;
    atom invoke_callback;
}
