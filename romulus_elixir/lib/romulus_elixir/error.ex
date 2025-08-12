defmodule RomulusElixir.Error do
  @moduledoc """
  Comprehensive error handling for Romulus infrastructure management.
  
  This module provides structured error types for different failure scenarios
  in infrastructure management, making it easier to handle and report errors
  appropriately.
  
  ## Error Types
  
  - `ConfigError` - Configuration loading and validation failures
  - `StateError` - State discovery and validation failures  
  - `PlanningError` - Plan generation and validation failures
  - `ExecutionError` - Action execution failures
  - `LibvirtError` - Libvirt operation failures
  - `TimeoutError` - Operation timeout failures
  - `DependencyError` - Resource dependency violations
  - `ResourceError` - Resource-specific errors
  
  ## Usage
  
      iex> {:error, %ConfigError{}} = Config.load("invalid.yaml")
      iex> {:error, %ExecutionError{}} = Executor.execute(invalid_plan)
  
  """
  
  # Configuration-related errors
  defmodule ConfigError do
    @moduledoc """
    Errors related to configuration loading and validation.
    """
    
    defexception [:message, :type, :details, :file_path]
    
    @type t :: %__MODULE__{
      message: String.t(),
      type: :load_failed | :validation_failed | :parse_failed | :file_not_found,
      details: map() | nil,
      file_path: String.t() | nil
    }
    
    def new(type, message, opts \\ []) do
      %__MODULE__{
        message: message,
        type: type,
        details: Keyword.get(opts, :details),
        file_path: Keyword.get(opts, :file_path)
      }
    end
    
    def format_error(%__MODULE__{} = error) do
      base_message = "Configuration Error (#{error.type}): #{error.message}"
      
      additional_info = [
        if(error.file_path, do: "File: #{error.file_path}", else: nil),
        if(error.details, do: "Details: #{inspect(error.details)}", else: nil)
      ]
      |> Enum.filter(& &1)
      
      case additional_info do
        [] -> base_message
        info -> Enum.join([base_message | info], "\n  ")
      end
    end
  end
  
  # State-related errors  
  defmodule StateError do
    @moduledoc """
    Errors related to infrastructure state discovery and validation.
    """
    
    defexception [:message, :type, :resource_type, :resource_name, :details]
    
    @type t :: %__MODULE__{
      message: String.t(),
      type: :discovery_failed | :validation_failed | :inconsistent_state | :serialization_failed,
      resource_type: atom() | nil,
      resource_name: String.t() | nil, 
      details: map() | nil
    }
    
    def new(type, message, opts \\ []) do
      %__MODULE__{
        message: message,
        type: type,
        resource_type: Keyword.get(opts, :resource_type),
        resource_name: Keyword.get(opts, :resource_name),
        details: Keyword.get(opts, :details)
      }
    end
    
    def format_error(%__MODULE__{} = error) do
      base_message = "State Error (#{error.type}): #{error.message}"
      
      resource_info = case {error.resource_type, error.resource_name} do
        {nil, nil} -> nil
        {type, nil} -> "Resource Type: #{type}"
        {nil, name} -> "Resource: #{name}"
        {type, name} -> "Resource: #{type}/#{name}"
      end
      
      additional_info = [
        resource_info,
        if(error.details, do: "Details: #{inspect(error.details)}", else: nil)
      ]
      |> Enum.filter(& &1)
      
      case additional_info do
        [] -> base_message
        info -> Enum.join([base_message | info], "\n  ")
      end
    end
  end
  
  # Planning-related errors
  defmodule PlanningError do
    @moduledoc """
    Errors related to infrastructure plan generation and validation.
    """
    
    defexception [:message, :type, :action, :resource_conflicts, :details]
    
    @type t :: %__MODULE__{
      message: String.t(),
      type: :plan_generation_failed | :dependency_violation | :resource_conflict | :validation_failed,
      action: map() | nil,
      resource_conflicts: [String.t()] | nil,
      details: map() | nil
    }
    
    def new(type, message, opts \\ []) do
      %__MODULE__{
        message: message,
        type: type,
        action: Keyword.get(opts, :action),
        resource_conflicts: Keyword.get(opts, :resource_conflicts, []),
        details: Keyword.get(opts, :details)
      }
    end
    
    def format_error(%__MODULE__{} = error) do
      base_message = "Planning Error (#{error.type}): #{error.message}"
      
      additional_info = [
        if(error.action, do: "Action: #{inspect(error.action)}", else: nil),
        if(length(error.resource_conflicts || []) > 0, 
           do: "Conflicting Resources: #{Enum.join(error.resource_conflicts, ", ")}", 
           else: nil),
        if(error.details, do: "Details: #{inspect(error.details)}", else: nil)
      ]
      |> Enum.filter(& &1)
      
      case additional_info do
        [] -> base_message
        info -> Enum.join([base_message | info], "\n  ")
      end
    end
  end
  
  # Execution-related errors
  defmodule ExecutionError do
    @moduledoc """
    Errors related to infrastructure action execution.
    """
    
    defexception [:message, :type, :action, :resource_name, :step, :exit_code, :details]
    
    @type t :: %__MODULE__{
      message: String.t(),
      type: :action_failed | :timeout | :rollback_failed | :precondition_failed | :postcondition_failed,
      action: map() | nil,
      resource_name: String.t() | nil,
      step: String.t() | nil,
      exit_code: integer() | nil,
      details: map() | nil
    }
    
    def new(type, message, opts \\ []) do
      %__MODULE__{
        message: message,
        type: type,
        action: Keyword.get(opts, :action),
        resource_name: Keyword.get(opts, :resource_name),
        step: Keyword.get(opts, :step),
        exit_code: Keyword.get(opts, :exit_code),
        details: Keyword.get(opts, :details)
      }
    end
    
    def format_error(%__MODULE__{} = error) do
      base_message = "Execution Error (#{error.type}): #{error.message}"
      
      additional_info = [
        if(error.resource_name, do: "Resource: #{error.resource_name}", else: nil),
        if(error.step, do: "Step: #{error.step}", else: nil),
        if(error.exit_code, do: "Exit Code: #{error.exit_code}", else: nil),
        if(error.action, do: "Action: #{inspect(error.action)}", else: nil),
        if(error.details, do: "Details: #{inspect(error.details)}", else: nil)
      ]
      |> Enum.filter(& &1)
      
      case additional_info do
        [] -> base_message
        info -> Enum.join([base_message | info], "\n  ")
      end
    end
  end
  
  # Libvirt-specific errors
  defmodule LibvirtError do
    @moduledoc """
    Errors related to libvirt operations and virsh commands.
    """
    
    defexception [:message, :type, :command, :output, :exit_code, :timeout, :details]
    
    @type t :: %__MODULE__{
      message: String.t(),
      type: :command_failed | :timeout | :connection_failed | :resource_exists | :resource_not_found,
      command: String.t() | nil,
      output: String.t() | nil,
      exit_code: integer() | nil,
      timeout: integer() | nil,
      details: map() | nil
    }
    
    def new(type, message, opts \\ []) do
      %__MODULE__{
        message: message,
        type: type,
        command: Keyword.get(opts, :command),
        output: Keyword.get(opts, :output),
        exit_code: Keyword.get(opts, :exit_code),
        timeout: Keyword.get(opts, :timeout),
        details: Keyword.get(opts, :details)
      }
    end
    
    def format_error(%__MODULE__{} = error) do
      base_message = "Libvirt Error (#{error.type}): #{error.message}"
      
      additional_info = [
        if(error.command, do: "Command: #{error.command}", else: nil),
        if(error.exit_code, do: "Exit Code: #{error.exit_code}", else: nil),
        if(error.timeout, do: "Timeout: #{error.timeout}ms", else: nil),
        if(error.output && String.trim(error.output) != "", do: "Output: #{String.trim(error.output)}", else: nil),
        if(error.details, do: "Details: #{inspect(error.details)}", else: nil)
      ]
      |> Enum.filter(& &1)
      
      case additional_info do
        [] -> base_message
        info -> Enum.join([base_message | info], "\n  ")
      end
    end
  end
  
  # Timeout-specific errors
  defmodule TimeoutError do
    @moduledoc """
    Errors related to operation timeouts.
    """
    
    defexception [:message, :operation, :timeout_ms, :elapsed_ms, :details]
    
    @type t :: %__MODULE__{
      message: String.t(),
      operation: String.t() | nil,
      timeout_ms: integer() | nil,
      elapsed_ms: integer() | nil,
      details: map() | nil
    }
    
    def new(operation, timeout_ms, opts \\ []) do
      elapsed_ms = Keyword.get(opts, :elapsed_ms, timeout_ms)
      message = Keyword.get(opts, :message, "Operation '#{operation}' timed out after #{timeout_ms}ms")
      
      %__MODULE__{
        message: message,
        operation: operation,
        timeout_ms: timeout_ms,
        elapsed_ms: elapsed_ms,
        details: Keyword.get(opts, :details)
      }
    end
    
    def format_error(%__MODULE__{} = error) do
      base_message = "Timeout Error: #{error.message}"
      
      timing_info = case {error.timeout_ms, error.elapsed_ms} do
        {nil, nil} -> nil
        {timeout, nil} -> "Timeout: #{timeout}ms"
        {nil, elapsed} -> "Elapsed: #{elapsed}ms"
        {timeout, elapsed} when timeout == elapsed -> "Timeout: #{timeout}ms"
        {timeout, elapsed} -> "Timeout: #{timeout}ms, Elapsed: #{elapsed}ms"
      end
      
      additional_info = [
        if(error.operation, do: "Operation: #{error.operation}", else: nil),
        timing_info,
        if(error.details, do: "Details: #{inspect(error.details)}", else: nil)
      ]
      |> Enum.filter(& &1)
      
      case additional_info do
        [] -> base_message
        info -> Enum.join([base_message | info], "\n  ")
      end
    end
  end
  
  # Dependency-related errors
  defmodule DependencyError do
    @moduledoc """
    Errors related to resource dependencies and ordering.
    """
    
    defexception [:message, :type, :resource, :dependency, :cycle, :details]
    
    @type t :: %__MODULE__{
      message: String.t(),
      type: :missing_dependency | :circular_dependency | :dependency_failed | :ordering_violation,
      resource: String.t() | nil,
      dependency: String.t() | nil,
      cycle: [String.t()] | nil,
      details: map() | nil
    }
    
    def new(type, message, opts \\ []) do
      %__MODULE__{
        message: message,
        type: type,
        resource: Keyword.get(opts, :resource),
        dependency: Keyword.get(opts, :dependency),
        cycle: Keyword.get(opts, :cycle, []),
        details: Keyword.get(opts, :details)
      }
    end
    
    def format_error(%__MODULE__{} = error) do
      base_message = "Dependency Error (#{error.type}): #{error.message}"
      
      additional_info = [
        if(error.resource, do: "Resource: #{error.resource}", else: nil),
        if(error.dependency, do: "Dependency: #{error.dependency}", else: nil),
        if(length(error.cycle || []) > 0, 
           do: "Cycle: #{Enum.join(error.cycle, " -> ")}", 
           else: nil),
        if(error.details, do: "Details: #{inspect(error.details)}", else: nil)
      ]
      |> Enum.filter(& &1)
      
      case additional_info do
        [] -> base_message
        info -> Enum.join([base_message | info], "\n  ")
      end
    end
  end
  
  # Resource-specific errors
  defmodule ResourceError do
    @moduledoc """
    Errors related to specific resource operations and validation.
    """
    
    defexception [:message, :type, :resource_type, :resource_name, :operation, :constraint, :details]
    
    @type t :: %__MODULE__{
      message: String.t(),
      type: :validation_failed | :constraint_violated | :resource_busy | :insufficient_resources | :operation_not_supported,
      resource_type: atom() | nil,
      resource_name: String.t() | nil,
      operation: atom() | nil,
      constraint: String.t() | nil,
      details: map() | nil
    }
    
    def new(type, message, opts \\ []) do
      %__MODULE__{
        message: message,
        type: type,
        resource_type: Keyword.get(opts, :resource_type),
        resource_name: Keyword.get(opts, :resource_name),
        operation: Keyword.get(opts, :operation),
        constraint: Keyword.get(opts, :constraint),
        details: Keyword.get(opts, :details)
      }
    end
    
    def format_error(%__MODULE__{} = error) do
      base_message = "Resource Error (#{error.type}): #{error.message}"
      
      resource_info = case {error.resource_type, error.resource_name} do
        {nil, nil} -> nil
        {type, nil} -> "Resource Type: #{type}"
        {nil, name} -> "Resource: #{name}"
        {type, name} -> "Resource: #{type}/#{name}"
      end
      
      additional_info = [
        resource_info,
        if(error.operation, do: "Operation: #{error.operation}", else: nil),
        if(error.constraint, do: "Constraint: #{error.constraint}", else: nil),
        if(error.details, do: "Details: #{inspect(error.details)}", else: nil)
      ]
      |> Enum.filter(& &1)
      
      case additional_info do
        [] -> base_message
        info -> Enum.join([base_message | info], "\n  ")
      end
    end
  end
  
  @doc """
  Format any Romulus error for human-readable display.
  
  ## Examples
  
      iex> error = ConfigError.new(:load_failed, "File not found", file_path: "config.yaml")
      iex> Error.format(error)
      "Configuration Error (load_failed): File not found\\n  File: config.yaml"
  
  """
  def format(error) do
    case error do
      %ConfigError{} -> ConfigError.format_error(error)
      %StateError{} -> StateError.format_error(error)
      %PlanningError{} -> PlanningError.format_error(error)
      %ExecutionError{} -> ExecutionError.format_error(error)
      %LibvirtError{} -> LibvirtError.format_error(error)
      %TimeoutError{} -> TimeoutError.format_error(error)
      %DependencyError{} -> DependencyError.format_error(error)
      %ResourceError{} -> ResourceError.format_error(error)
      _ -> inspect(error)
    end
  end
  
  @doc """
  Create an error context for better error reporting.
  
  ## Examples
  
      iex> Error.with_context("Creating VM", fn ->
      ...>   {:error, LibvirtError.new(:command_failed, "virsh failed")}
      ...> end)
      {:error, %ExecutionError{message: "Creating VM failed: virsh failed"}}
  
  """
  def with_context(context, fun) when is_function(fun, 0) do
    case fun.() do
      {:ok, result} -> 
        {:ok, result}
      {:error, error} ->
        {:error, ExecutionError.new(:action_failed, "#{context} failed: #{format(error)}", step: context)}
    end
  end
  
  @doc """
  Convert legacy error tuples to structured errors.
  
  ## Examples
  
      iex> Error.from_legacy({:config_load_failed, :enoent})
      %ConfigError{type: :file_not_found, message: "Configuration file not found"}
  
  """
  def from_legacy(error_tuple) do
    case error_tuple do
      {:config_load_failed, :enoent} ->
        ConfigError.new(:file_not_found, "Configuration file not found")
      {:config_load_failed, %{} = validation_error} ->
        ConfigError.new(:validation_failed, "Configuration validation failed", details: validation_error)
      {:command_failed, code, output} ->
        LibvirtError.new(:command_failed, "Command failed", exit_code: code, output: output)
      {:timeout, operation} ->
        TimeoutError.new(operation, 30_000)
      {reason, message} when is_atom(reason) and is_binary(message) ->
        ExecutionError.new(:action_failed, message, details: %{reason: reason})
      other ->
        ExecutionError.new(:action_failed, "Unexpected error", details: %{error: other})
    end
  end
end
