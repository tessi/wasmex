# Test the native wit_exported_resources function directly
wit_content = File.read!("test/component_fixtures/counter-component/wit/world.wit")

IO.puts("Testing native wit_exported_resources function...")
result = :wasmex_native.wit_exported_resources(wit_content)

IO.inspect(result, label: "Raw output from native function", limit: :infinity)
