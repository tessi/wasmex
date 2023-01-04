defmodule Wasmex.StoreLimits do
  @moduledoc ~S"""
  Configures limits to limit resource creation within a `Wasmex.Store`.

  Whenever resources such as linear memory, tables, or instances are
  allocated the `StoreLimits` specified here are enforced.

  ## Options

    * `:memory_size` - The maximum number of bytes a linear memory can grow to. Growing a linear memory beyond this limit will fail. By default, linear memory will not be limited.
    * `:table_elements` - The maximum number of elements in a table. Growing a table beyond this limit will fail. By default, table elements will not be limited.
    * `:instances` - The maximum number of instances that can be created for a `Wasmex.Store`. Module instantiation will fail if this limit is exceeded. This value defaults to 10,000.
    * `:tables` - The maximum number of tables that can be created for a `Wasmex.Store`. Module instantiation will fail if this limit is exceeded. This value defaults to 10,000.
    * `:memories` - The maximum number of linear memories that can be created for a `Wasmex.Store`. Instantiation will fail with an error if this limit is exceeded. This value defaults to 10,000.

  ## Example

      iex> Wasmex.Store.new(%Wasmex.StoreLimits{
      ...>   memory_size: 1_000_000,
      ...>   table_elements: 100_000,
      ...>   instances: 2,
      ...>   tables: 10
      ...>   memories: 10
      ...> })
  """

  defstruct [:memory_size, :table_elements, :instances, :tables, :memories]

  @type t :: %__MODULE__{
          memory_size: non_neg_integer() | nil,
          table_elements: non_neg_integer() | nil,
          instances: non_neg_integer() | nil,
          tables: non_neg_integer() | nil,
          memories: non_neg_integer() | nil
        }
end
