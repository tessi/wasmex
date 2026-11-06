defmodule Wasmex.StoreLimits do
  @moduledoc ~S"""
  Configures limits to limit resource creation within a `Wasmex.Store`.

  Whenever resources such as linear memory, tables, or instances are
  allocated the `StoreLimits` specified here are enforced.

  Defaults apply to core, WASI, and component stores. Omitting the limits
  or leaving an individual field as `nil` uses the default for that field.
  The size limits apply to each memory or table individually, including its
  initial size. Set explicit limits to support workloads that need larger resources.

  ## Options

    * `:memory_size` - The maximum size of each linear memory in bytes. Defaults to 256 MiB (268,435,456 bytes).
    * `:table_elements` - The maximum number of elements in each table. Defaults to 100,000.
    * `:instances` - The maximum number of instances that can be created for a `Wasmex.Store`. Module instantiation will fail if this limit is exceeded. This value defaults to 10,000.
    * `:tables` - The maximum number of tables that can be created for a `Wasmex.Store`. Module instantiation will fail if this limit is exceeded. This value defaults to 10,000.
    * `:memories` - The maximum number of linear memories that can be created for a `Wasmex.Store`. Instantiation will fail with an error if this limit is exceeded. This value defaults to 10,000.

  ## Example

      iex> Wasmex.Store.new(%Wasmex.StoreLimits{
      ...>   memory_size: 1_000_000,
      ...>   table_elements: 100_000,
      ...>   instances: 2,
      ...>   tables: 10,
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
