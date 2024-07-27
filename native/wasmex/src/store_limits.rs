// Due to a clippy bug it thinks we needlessly borrow stuff
// when defining the ExStoreLimits struct
// see: https://github.com/rust-lang/rust-clippy/issues/9778
#![allow(clippy::needless_borrow)]

use rustler::NifStruct;
use wasmtime::ResourceLimiterAsync;

#[derive(Clone, Debug)]
pub struct StoreLimitsAsync {
    memory_size: Option<usize>,
    table_elements: Option<u32>,
    instances: usize,
    tables: usize,
    memories: usize,
    trap_on_grow_failure: bool,
}

impl Default for StoreLimitsAsync {
    fn default() -> Self {
        Self {
            memory_size: None,
            table_elements: None,
            instances: wasmtime::DEFAULT_INSTANCE_LIMIT,
            tables: wasmtime::DEFAULT_TABLE_LIMIT,
            memories: wasmtime::DEFAULT_MEMORY_LIMIT,
            trap_on_grow_failure: false,
        }
    }
}

#[wiggle::async_trait]
impl ResourceLimiterAsync for StoreLimitsAsync {
    async fn memory_growing(
        &mut self,
        _current: usize,
        desired: usize,
        maximum: Option<usize>,
    ) -> wiggle::anyhow::Result<bool> {
        let allow = match self.memory_size {
            Some(limit) if desired > limit => false,
            _ => match maximum {
                Some(max) if desired > max => false,
                _ => true,
            },
        };
        if !allow && self.trap_on_grow_failure {
            wiggle::anyhow::bail!("forcing trap when growing memory to {desired} bytes")
        } else {
            Ok(allow)
        }
    }
    async fn table_growing(
        &mut self,
        _current: u32,
        desired: u32,
        maximum: Option<u32>,
    ) -> wiggle::anyhow::Result<bool> {
        let allow = match self.table_elements {
            Some(limit) if desired > limit => false,
            _ => match maximum {
                Some(max) if desired > max => false,
                _ => true,
            },
        };
        if !allow && self.trap_on_grow_failure {
            wiggle::anyhow::bail!("forcing trap when growing table to {desired} elements")
        } else {
            Ok(allow)
        }
    }

    fn instances(&self) -> usize {
        self.instances
    }

    fn tables(&self) -> usize {
        self.tables
    }

    fn memories(&self) -> usize {
        self.memories
    }
}

/// Used to build [`StoreLimitsAsync`].
pub struct StoreLimitsAsyncBuilder(StoreLimitsAsync);

impl StoreLimitsAsyncBuilder {
    /// Creates a new [`StoreLimitsAsyncBuilder`].
    ///
    /// See the documentation on each builder method for the default for each
    /// value.
    pub fn new() -> Self {
        Self(StoreLimitsAsync::default())
    }

    /// The maximum number of bytes a linear memory can grow to.
    ///
    /// Growing a linear memory beyond this limit will fail. This limit is
    /// applied to each linear memory individually, so if a wasm module has
    /// multiple linear memories then they're all allowed to reach up to the
    /// `limit` specified.
    ///
    /// By default, linear memory will not be limited.
    pub fn memory_size(mut self, limit: usize) -> Self {
        self.0.memory_size = Some(limit);
        self
    }

    /// The maximum number of elements in a table.
    ///
    /// Growing a table beyond this limit will fail. This limit is applied to
    /// each table individually, so if a wasm module has multiple tables then
    /// they're all allowed to reach up to the `limit` specified.
    ///
    /// By default, table elements will not be limited.
    pub fn table_elements(mut self, limit: u32) -> Self {
        self.0.table_elements = Some(limit);
        self
    }

    /// The maximum number of instances that can be created for a [`Store`](crate::Store).
    ///
    /// Module instantiation will fail if this limit is exceeded.
    ///
    /// This value defaults to 10,000.
    pub fn instances(mut self, limit: usize) -> Self {
        self.0.instances = limit;
        self
    }

    /// The maximum number of tables that can be created for a [`Store`](crate::Store).
    ///
    /// Module instantiation will fail if this limit is exceeded.
    ///
    /// This value defaults to 10,000.
    pub fn tables(mut self, tables: usize) -> Self {
        self.0.tables = tables;
        self
    }

    /// The maximum number of linear memories that can be created for a [`Store`](crate::Store).
    ///
    /// Instantiation will fail with an error if this limit is exceeded.
    ///
    /// This value defaults to 10,000.
    pub fn memories(mut self, memories: usize) -> Self {
        self.0.memories = memories;
        self
    }

    /// Indicates that a trap should be raised whenever a growth operation
    /// would fail.
    ///
    /// This operation will force `memory.grow` and `table.grow` instructions
    /// to raise a trap on failure instead of returning -1. This is not
    /// necessarily spec-compliant, but it can be quite handy when debugging a
    /// module that fails to allocate memory and might behave oddly as a result.
    ///
    /// This value defaults to `false`.
    pub fn trap_on_grow_failure(mut self, trap: bool) -> Self {
        self.0.trap_on_grow_failure = trap;
        self
    }

    /// Consumes this builder and returns the [`StoreLimitsAsync`].
    pub fn build(self) -> StoreLimitsAsync {
        self.0
    }
}

#[derive(NifStruct)]
#[module = "Wasmex.StoreLimits"]
pub struct ExStoreLimits {
    memory_size: Option<usize>,
    table_elements: Option<u32>,
    instances: Option<usize>,
    tables: Option<usize>,
    memories: Option<usize>,
}

impl ExStoreLimits {
    pub fn to_wasmtime(&self) -> StoreLimitsAsync {
        let limits = StoreLimitsAsyncBuilder::new();

        let limits = if let Some(memory_size) = self.memory_size {
            limits.memory_size(memory_size)
        } else {
            limits
        };

        let limits = if let Some(table_elements) = self.table_elements {
            limits.table_elements(table_elements)
        } else {
            limits
        };

        let limits = if let Some(instances) = self.instances {
            limits.instances(instances)
        } else {
            limits
        };

        let limits = if let Some(tables) = self.tables {
            limits.tables(tables)
        } else {
            limits
        };

        let limits = if let Some(memories) = self.memories {
            limits.memories(memories)
        } else {
            limits
        };

        limits.build()
    }
}
