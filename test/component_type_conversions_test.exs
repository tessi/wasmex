defmodule Wasmex.ComponentTypeConversionsTest do
  use ExUnit.Case, async: true

  alias Wasmex.Wasi.WasiP2Options

  describe "component type conversions" do
    defmodule Point, do: defstruct([:x, :y])

    def start_component(imports \\ TestHelper.component_type_conversions_import_map(), opts \\ []) do
      component_bytes = File.read!(TestHelper.component_type_conversions_file_path())
      defaults = [bytes: component_bytes, imports: imports, wasi: %WasiP2Options{}]

      start_supervised!({Wasmex.Components, Keyword.merge(defaults, opts)})
    end

    test "integer types" do
      component_pid = start_component()

      # all the integer types
      for type <- ["u8", "u16", "u32", "u64", "s8", "s16", "s32", "s64"] do
        assert {:ok, 123} =
                 Wasmex.Components.call_function(component_pid, "export-id-#{type}", [123])

        assert {:error, "Could not convert Atom" <> _} =
                 Wasmex.Components.call_function(component_pid, "export-id-#{type}", [:bad])
      end
    end

    test "float types" do
      component_pid = start_component()

      assert {:ok, float} =
               Wasmex.Components.call_function(component_pid, "export-id-f32", [123.4])

      assert_in_delta 123.4, float, 0.00001

      assert {:error, "Could not convert Integer to Float32"} =
               Wasmex.Components.call_function(component_pid, "export-id-f32", [123])

      assert {:ok, float} =
               Wasmex.Components.call_function(component_pid, "export-id-f64", [123.4])

      assert_in_delta 123.4, float, 0.00001

      assert {:error, "Could not convert Integer to Float64"} =
               Wasmex.Components.call_function(component_pid, "export-id-f64", [123])
    end

    test "booleans" do
      component_pid = start_component()

      assert {:ok, true} =
               Wasmex.Components.call_function(component_pid, "export-id-bool", [true])

      assert {:ok, false} =
               Wasmex.Components.call_function(component_pid, "export-id-bool", [false])

      assert {:ok, true} =
               Wasmex.Components.call_function(component_pid, "export-id-bool", [
                 "follows truthy' rules"
               ])

      assert {:ok, false} =
               Wasmex.Components.call_function(component_pid, "export-id-bool", [nil])
    end

    test "strings" do
      component_pid = start_component()

      assert {:ok, "hello world"} =
               Wasmex.Components.call_function(component_pid, "export-id-string", ["hello world"])

      assert {:ok, "hello_world"} =
               Wasmex.Components.call_function(component_pid, "export-id-string", [:hello_world])

      assert {:error, "Could not convert Integer to String"} =
               Wasmex.Components.call_function(component_pid, "export-id-string", [42])
    end

    test "list types" do
      component_pid = start_component()

      assert {:ok, [1, 2, 3]} =
               Wasmex.Components.call_function(component_pid, "export-id-list-u8", [[1, 2, 3]])

      assert {:error, "Could not convert Atom to U8 at \"list[1]\""} =
               Wasmex.Components.call_function(component_pid, "export-id-list-u8", [
                 [1, :two, "three"]
               ])

      assert {:error, _} =
               Wasmex.Components.call_function(component_pid, "export-id-list-u8", [[1 | 2]])
    end

    test "accepts binaries as byte-list arguments" do
      component_pid = start_component()

      assert {:ok, [0, 128, 255]} =
               Wasmex.Components.call_function(component_pid, "export-id-list-u8", [
                 <<0, 128, 255>>
               ])

      assert {:ok, []} =
               Wasmex.Components.call_function(component_pid, "export-id-list-u8", [<<>>])

      assert {:error, _reason} =
               Wasmex.Components.call_function(component_pid, "export-id-list-u8", [<<1::1>>])
    end

    test "accepts binaries returned by byte-list imports" do
      imports =
        Map.put(
          TestHelper.component_type_conversions_import_map(),
          "import-id-list-u8",
          {:fn, fn [0, 128, 255] -> <<255, 128, 0>> end}
        )

      component_pid = start_component(imports)

      assert {:ok, [255, 128, 0]} =
               Wasmex.Components.call_function(component_pid, "export-id-list-u8", [
                 [0, 128, 255]
               ])
    end

    test "encodes byte-list results and callback arguments as binaries when enabled" do
      imports =
        Map.put(
          TestHelper.component_type_conversions_import_map(),
          "import-id-list-u8",
          {:fn,
           fn
             <<0, 128, 255>> -> <<255, 128, 0>>
             <<>> -> []
           end}
        )

      component_pid = start_component(imports, binary_byte_lists: true)

      for input <- [<<0, 128, 255>>, [0, 128, 255]] do
        assert {:ok, <<255, 128, 0>>} =
                 Wasmex.Components.call_function(component_pid, "export-id-list-u8", [input])
      end

      assert {:ok, <<>>} =
               Wasmex.Components.call_function(component_pid, "export-id-list-u8", [<<>>])
    end

    test "encodes byte lists inside both result cases and options" do
      wat = ~S"""
      (component
        (type $bytes (list u8))
        (type $optional-bytes (option $bytes))
        (type $result (result $optional-bytes (error $bytes)))
        (core module $impl
          (memory (export "memory") 1)
          ;; ok(some(list)) at offset 0, error(empty list) at 16, bytes at 32.
          (data (i32.const 0) "\00\00\00\00\01\00\00\00\20\00\00\00\03\00\00\00\01")
          (data (i32.const 32) "\00\80\ff")
          (func (export "get") (param i32) (result i32)
            i32.const 0 i32.const 16 local.get 0 select))
        (core instance $impl (instantiate $impl))
        (alias core export $impl "memory" (core memory $memory))
        (func (export "get") (param "ok" bool) (result $result)
          (canon lift (core func $impl "get") (memory $memory))))
      """

      assert {:ok, bytes} = Wasmex.Wat.to_wasm(wat)
      pid = start_supervised!({Wasmex.Components, bytes: bytes, binary_byte_lists: true})

      assert {:ok, {:ok, {:some, <<0, 128, 255>>}}} =
               Wasmex.Components.call_function(pid, "get", [true])

      assert {:ok, {:error, <<>>}} = Wasmex.Components.call_function(pid, "get", [false])
    end

    test "tuple types" do
      component_pid = start_component()

      assert {:ok, {1, "two"}} =
               Wasmex.Components.call_function(component_pid, "export-id-tuple-u8-string", [
                 {1, "two"}
               ])

      assert {:ok, {1, "two"}} =
               Wasmex.Components.call_function(component_pid, "export-id-tuple-u8-string", [
                 {1, :two}
               ])

      assert {:error, "Could not convert Integer to String at \"tuple[1]\""} =
               Wasmex.Components.call_function(component_pid, "export-id-tuple-u8-string", [
                 {1, 2}
               ])
    end

    test "flags" do
      component_pid = start_component()

      assert {:ok, %{read: true, write: true, exec: true}} =
               Wasmex.Components.call_function(component_pid, "export-id-flags", [
                 %{read: true, write: true, exec: true}
               ])

      assert {:ok, %{read: true, exec: true}} =
               Wasmex.Components.call_function(component_pid, "export-id-flags", [
                 %{read: true, write: false, exec: true}
               ])

      assert {:ok, %{}} =
               Wasmex.Components.call_function(component_pid, "export-id-flags", [%{}])

      assert {:error, "Could not convert Integer to Flags" <> _} =
               Wasmex.Components.call_function(component_pid, "export-id-flags", [123])
    end

    test "converted flag aliases collapse before native validation" do
      component_bytes = File.read!(TestHelper.component_type_conversions_file_path())
      original_flags = <<4, "read", 5, "write", 4, "exec">>
      renamed_flags = <<4, "r-xx", 5, "write", 4, "exec">>
      patched_bytes = :binary.replace(component_bytes, original_flags, renamed_flags, [:global])
      assert patched_bytes != component_bytes

      component_pid =
        start_supervised!(
          {Wasmex.Components,
           bytes: patched_bytes,
           imports: TestHelper.component_type_conversions_import_map(),
           wasi: %WasiP2Options{}}
        )

      for flags <- [%{"r-xx" => true, r_xx: false}, %{"r-xx": true, r_xx: false}] do
        args = Wasmex.Components.FieldConverter.maybe_convert_args([flags], true)
        result = Wasmex.Components.call_function(component_pid, "export-id-flags", args)

        assert {:ok, %{r_xx: true}} =
                 Wasmex.Components.FieldConverter.maybe_convert_result(result, true, %{
                   "r-xx" => :r_xx
                 })
      end
    end

    test "enum types" do
      component_pid = start_component()

      assert {:ok, :a} = Wasmex.Components.call_function(component_pid, "export-id-enum", [:a])
      assert {:ok, :b} = Wasmex.Components.call_function(component_pid, "export-id-enum", ["b"])
      assert {:ok, :c} = Wasmex.Components.call_function(component_pid, "export-id-enum", [:c])

      assert {:error, "Enum value not found: not_existing"} =
               Wasmex.Components.call_function(component_pid, "export-id-enum", [:not_existing])

      assert {:error, "Could not convert Integer to Enum" <> _} =
               Wasmex.Components.call_function(component_pid, "export-id-enum", [1234])
    end

    test "simple record" do
      component_pid = start_component()

      assert {:ok, %{x: 1, y: 2}} =
               Wasmex.Components.call_function(component_pid, "export-id-point", [
                 %Point{x: 1, y: 2}
               ])

      assert {:ok, %{x: 1, y: 2}} =
               Wasmex.Components.call_function(component_pid, "export-id-point", [
                 %{"x" => 1, "y" => 2}
               ])

      assert {:error, "Expected 2 fields, got 0 - missing fields: x, y"} =
               Wasmex.Components.call_function(component_pid, "export-id-point", [%{"foo" => 12}])
    end

    test "option" do
      component_pid = start_component()

      assert {:ok, {:some, 123}} =
               Wasmex.Components.call_function(component_pid, "export-id-option-u8", [
                 {:some, 123}
               ])

      assert {:ok, :none} =
               Wasmex.Components.call_function(component_pid, "export-id-option-u8", [:none])

      assert {:error, "Invalid atom: random_atom, expected ':none' or '{:some, term}' tuple"} =
               Wasmex.Components.call_function(component_pid, "export-id-option-u8", [
                 :random_atom
               ])
    end

    test "result" do
      component_pid = start_component()

      assert {:ok, {:ok, 123}} =
               Wasmex.Components.call_function(component_pid, "export-id-result-u8-string", [
                 {:ok, 123}
               ])

      assert {:ok, {:error, "hello"}} =
               Wasmex.Components.call_function(component_pid, "export-id-result-u8-string", [
                 {:error, "hello"}
               ])

      assert {:error,
              "Invalid atom: broken, expected ':ok' or ':error' as first element in result-tuple"} =
               Wasmex.Components.call_function(component_pid, "export-id-result-u8-string", [
                 {:broken, "hello"}
               ])

      assert {:ok, {:ok, 123}} =
               Wasmex.Components.call_function(component_pid, "export-id-result-u8-none", [
                 {:ok, 123}
               ])

      assert {:ok, :error} =
               Wasmex.Components.call_function(component_pid, "export-id-result-u8-none", [:error])

      assert {:error, "Invalid atom: bad_atom, expected ':ok' or ':error' as result"} =
               Wasmex.Components.call_function(component_pid, "export-id-result-u8-none", [
                 :bad_atom
               ])

      assert {:error, "Result-type expected to have an :error atom, but got 'error' tuple"} =
               Wasmex.Components.call_function(component_pid, "export-id-result-u8-none", [
                 {:error, "type mismatch"}
               ])

      assert {:ok, :ok} =
               Wasmex.Components.call_function(component_pid, "export-id-result-none-string", [
                 :ok
               ])

      assert {:ok, {:error, "hello"}} =
               Wasmex.Components.call_function(component_pid, "export-id-result-none-string", [
                 {:error, "hello"}
               ])

      assert {:error, "Result-type expected to have an :ok atom, but got 'ok' tuple"} =
               Wasmex.Components.call_function(component_pid, "export-id-result-none-string", [
                 {:ok, 123}
               ])

      assert {:error, "Invalid atom: bad_ok, expected ':ok' or ':error' as result"} =
               Wasmex.Components.call_function(component_pid, "export-id-result-none-string", [
                 :bad_ok
               ])

      assert {:ok, :ok} =
               Wasmex.Components.call_function(component_pid, "export-id-result-none-none", [:ok])

      assert {:ok, :error} =
               Wasmex.Components.call_function(component_pid, "export-id-result-none-none", [
                 :error
               ])

      assert {:error, "Invalid atom: bad_atom, expected ':ok' or ':error' as result"} =
               Wasmex.Components.call_function(component_pid, "export-id-result-none-none", [
                 :bad_atom
               ])

      assert {:error, "Result-type expected to have an :ok atom, but got 'ok' tuple"} =
               Wasmex.Components.call_function(component_pid, "export-id-result-none-none", [
                 {:ok, 123}
               ])

      assert {:error, "Result-type expected to have an :error atom, but got 'error' tuple"} =
               Wasmex.Components.call_function(component_pid, "export-id-result-none-none", [
                 {:error, "type mismatch"}
               ])
    end

    test "variant" do
      component_pid = start_component()

      assert {:ok, :none} =
               Wasmex.Components.call_function(component_pid, "export-id-variant", [:none])

      # works the same when using a string to identify the variant
      assert {:ok, :none} =
               Wasmex.Components.call_function(component_pid, "export-id-variant", ["none"])

      assert {:ok, {:str, "hello"}} =
               Wasmex.Components.call_function(component_pid, "export-id-variant", [
                 {:str, "hello"}
               ])

      assert {:ok, {:int, 123}} =
               Wasmex.Components.call_function(component_pid, "export-id-variant", [{:int, 123}])

      assert {:ok, {:float, float}} =
               Wasmex.Components.call_function(component_pid, "export-id-variant", [
                 {:float, 123.4}
               ])

      assert_in_delta 123.4, float, 0.00001

      assert {:ok, {:boolean, true}} =
               Wasmex.Components.call_function(component_pid, "export-id-variant", [
                 {:boolean, true}
               ])

      assert {:ok, {:point, %{x: 1, y: 2}}} =
               Wasmex.Components.call_function(component_pid, "export-id-variant", [
                 {:point, %Point{x: 1, y: 2}}
               ])

      assert {:error, _reason} =
               Wasmex.Components.call_function(component_pid, "export-id-variant", [
                 {:"list-point", [%Point{x: 1, y: 2} | :improper_tail]}
               ])

      assert {:ok, {:"list-point", [%{x: 1, y: 2}, %{x: 3, y: 4}]}} =
               Wasmex.Components.call_function(component_pid, "export-id-variant", [
                 {:"list-point", [%Point{x: 1, y: 2}, %Point{x: 3, y: 4}]}
               ])

      assert {:ok, {:"option-u8", {:some, 123}}} =
               Wasmex.Components.call_function(component_pid, "export-id-variant", [
                 {:"option-u8", {:some, 123}}
               ])

      assert {:ok, {:"option-u8", :none}} =
               Wasmex.Components.call_function(component_pid, "export-id-variant", [
                 {:"option-u8", :none}
               ])

      assert {:ok, {:"enum-type", :a}} =
               Wasmex.Components.call_function(component_pid, "export-id-variant", [
                 {:"enum-type", :a}
               ])
    end

    test "char" do
      component_pid = start_component()

      # Test with a Unicode character passed as a string
      assert {:ok, "A"} = Wasmex.Components.call_function(component_pid, "export-id-char", ["A"])

      # Test with a Unicode character from an integer code point
      assert {:ok, "Ω"} = Wasmex.Components.call_function(component_pid, "export-id-char", [937])

      # Test with an emoji
      assert {:ok, "🚀"} = Wasmex.Components.call_function(component_pid, "export-id-char", ["🚀"])

      assert {:ok, "B"} =
               Wasmex.Components.call_function(component_pid, "export-id-char", [~c"B"])

      assert {:error, "Could not convert Atom to Char"} =
               Wasmex.Components.call_function(component_pid, "export-id-char", [:tree])
    end

    test "complex record" do
      component_pid = start_component()

      complex_record = %{
        str: "hello",
        int: 123,
        float: 123.456,
        boolean: true,
        "list-u8": <<1, 2, 3>>,
        "list-point": [%{x: 1, y: 2}, %{x: 3, y: 4}],
        "option-u8": {:some, 123},
        "option-string": {:some, "hello"},
        "option-point": {:some, %{x: 1, y: 2}},
        "option-list-point": {:some, [%{x: 1, y: 2}, %{x: 3, y: 4}]},
        "result-u8-string": {:error, "hello"},
        "empty-result": :ok,
        "tuple-u8-point": {123, %{x: 1, y: 2}}
      }

      assert {:ok, result} =
               Wasmex.Components.call_function(component_pid, "export-id-record-complex", [
                 complex_record
               ])

      assert result.str == "hello"
      assert result.int == 123
      assert_in_delta 123.456, result.float, 0.00001
      assert result.boolean == true
      assert Map.get(result, :"list-u8") == [1, 2, 3]
      assert Map.get(result, :"list-point") == [%{x: 1, y: 2}, %{x: 3, y: 4}]
      assert Map.get(result, :"option-u8") == {:some, 123}
      assert Map.get(result, :"option-string") == {:some, "hello"}
      assert Map.get(result, :"option-point") == {:some, %{x: 1, y: 2}}
      assert Map.get(result, :"option-list-point") == {:some, [%{x: 1, y: 2}, %{x: 3, y: 4}]}
      assert Map.get(result, :"result-u8-string") == {:error, "hello"}
      assert Map.get(result, :"empty-result") == :ok
      assert Map.get(result, :"tuple-u8-point") == {123, %{x: 1, y: 2}}

      erroneus_record = %{
        complex_record
        | "option-list-point": {:some, [%{x: 1, y: 2}, %{x: 3, why: 4}]}
      }

      assert {:error,
              "Expected 2 fields, got 1 - missing fields: y at \"record('option-list-point').option(some).list[1]\""} =
               Wasmex.Components.call_function(component_pid, "export-id-record-complex", [
                 erroneus_record
               ])

      assert {:error, "Could not convert Binary to List" <> reason} =
               Wasmex.Components.call_function(component_pid, "export-id-record-complex", [
                 %{complex_record | "list-point": <<1, 2, 3>>}
               ])

      assert reason =~ "record('list-point')"

      stop_supervised!(Wasmex.Components)
      imports = TestHelper.component_type_conversions_import_map()
      pid = start_component(imports, binary_byte_lists: true)

      for input <- [<<0, 128, 255>>, [0, 128, 255]] do
        assert {:ok, %{"list-u8": <<0, 128, 255>>}} =
                 Wasmex.Components.call_function(pid, "export-id-record-complex", [
                   %{complex_record | "list-u8": input}
                 ])
      end

      assert {:error, _} =
               Wasmex.Components.call_function(pid, "export-id-record-complex", [
                 %{complex_record | "list-u8": [256]}
               ])

      input = %{complex_record | "list-u8": <<>>, "list-point": []}

      assert {:ok, %{"list-u8": <<>>, "list-point": []}} =
               Wasmex.Components.call_function(pid, "export-id-record-complex", [input])
    end
  end

  describe "package imports / shadowing default wassi implementation" do
    test "get random bytes with default wasi:random/random" do
      component_pid = start_component()

      assert {:ok, bytes} =
               Wasmex.Components.call_function(component_pid, "get-random-bytes", [32])

      assert length(bytes) == 32
      refute Enum.all?(bytes, &(&1 == 0))
    end

    test "get random bytes with shadowing wasi:random/random in Elixir" do
      component_pid =
        %{
          "wasi:random/random@0.2.12" => %{
            "get-random-bytes" => {:fn, &List.duplicate(0, &1)}
          }
        }
        |> Map.merge(TestHelper.component_type_conversions_import_map())
        |> start_component()

      assert {:ok, bytes} =
               Wasmex.Components.call_function(component_pid, "get-random-bytes", [32])

      assert length(bytes) == 32
      assert Enum.all?(bytes, &(&1 == 0))
    end
  end
end
