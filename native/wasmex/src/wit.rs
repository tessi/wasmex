use rustler::{NifResult, Term};
use wit_parser::{Resolve, WorldItem};

#[rustler::nif(name = "wit_exported_functions")]
pub fn exported_functions<'a>(env: rustler::Env<'a>, path: String, wit: String) -> NifResult<Term<'a>> {
  let mut resolve = Resolve::new();
  let id = resolve.push_str(path, &wit).unwrap();
  let world_id = resolve.select_world(id, None).unwrap();
  let exports = &resolve.worlds[world_id].exports;
  let exported_functions = exports.iter().filter_map(|(_key, value)|
    match value {
        WorldItem::Function(function) => {
          Some((&function.name, function.params.len()))
        }
        _ => None
    }
  ).collect::<Vec<(&String, usize)>>();
  Ok(Term::map_from_pairs(env, exported_functions.as_slice()).unwrap())
}