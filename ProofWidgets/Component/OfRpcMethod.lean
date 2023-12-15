import Lean.Elab.ElabRules
import ProofWidgets.Component.Basic
import ProofWidgets.Data.Html

namespace ProofWidgets
open Lean Server Meta Elab Term

def ofRpcMethodTemplate := include_str ".." / ".." / ".lake" / "build" / "js" / "ofRpcMethod.js"

/-- The elaborator `mk_rpc_widget%` allows writing certain widgets in Lean instead of JavaScript.
Specifically, given an RPC method of type `Props → RequestM (RequestTask Html)`
(that computes an output HTML tree given input props)
it produces a widget component of type `Component LProps IProps`.
(See the `Component` docstring for definitions of `LProps`/`IProps`.)

For example, we can write:
```lean
open Lean Server

-- Assuming `LProps`, `IProps` are structures.
structure Props extends LProps, IProps
  deriving RpcEncodable

@[server_rpc_method]
def MyComponent.rpc (ps : Props) : RequestM (RequestTask Html) :=
  ...

@[widget_module]
def MyComponent : Component LProps IProps :=
  mk_rpc_widget% MyComponent.rpc
```

If both `LProps` and `IProps` are structures,
then `Props` should contain a subset of both structures' fields.
More generally, writing `TS(α)` for the TypeScript type describing
the JSON encoding of `α` as per its `RpcEncodable` instance,
in TypeScript's structural type system
the intersection type `TS(LProps) & TS(IProps)` should extend `TS(Props)`.
This condition is assumed, not checked.

⚠️ However, note that there are several limitations on what such component can do
compared to ones written natively in TypeScript or JavaScript:
- It must be pure, i.e. cannot directly store any React state.
  Child components may store state as usual.
- It cannot pass closures as props to the child components that it returns.
  For example, it is not currently possible to write click event handlers in Lean
  and pass them to a `<button onClick={..}>` child.
- Every time the input props change, the infoview has to send a message to the Lean server
  in order to invoke the RPC method.
  Thus there can be a noticeable visual delay between the input props changing
  and the display updating.
  Consequently, components whose props change at a high frequency
  (e.g. depending on the mouse position)
  should not be implemented using this method. -/
elab "mk_rpc_widget%" fn:term : term <= expectedType => do
  let α ← mkFreshExprMVar (some (.sort levelOne)) (userName := `α)
  let β ← mkFreshExprMVar (some (.sort levelOne)) (userName := `β)
  let compT ← mkAppM ``Component #[α, β]
  if !(← isDefEq expectedType compT) then
    throwError "expected type{indentD expectedType}\nis not of the form{indentD compT}"
  let γ ← mkFreshExprMVar (some (.sort levelOne)) (userName := `β)
  let arr ← mkArrow γ (← mkAppM ``RequestM #[← mkAppM ``RequestTask #[.const ``Html []]])
  let fn ← Term.elabTermEnsuringType fn arr
  let fn ← instantiateMVars fn
  let .const nm .. := fn
    | throwError "Expected the name of a constant, got a complex term{indentD fn}"
  if !(← builtinRpcProcedures.get).contains nm && !userRpcProcedures.contains (← getEnv) nm then
    throwError s!"'{nm}' is not a known RPC method. Use `@[server_rpc_method]` to register it."
  -- https://github.com/leanprover/lean4/issues/1415
  let code : StrLit := quote <| ofRpcMethodTemplate.replace "$RPC_METHOD" (toString nm)
  let valStx ← `({ javascript := $code })
  let ret ← elabTerm valStx expectedType
  return ret

end ProofWidgets
