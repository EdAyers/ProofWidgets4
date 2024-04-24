/-
 Copyright (c) 2021-2023 Wojciech Nawrocki. All rights reserved.
 Released under Apache 2.0 license as described in the file LICENSE.
 Authors: Wojciech Nawrocki, Sebastian Ullrich
 -/
import Lean.Data.Json.FromToJson
import Lean.Parser
import Lean.PrettyPrinter.Delaborator.Basic
import Lean.Server.Rpc.Basic

import ProofWidgets.Component.Basic

/-! We define a representation of HTML trees together with a JSX-like DSL for writing them. -/

namespace ProofWidgets
open Lean Server

/-- A HTML tree which may contain widget components. -/
inductive Html where
  /-- An `element "tag" attrs children` represents `<tag {...attrs}>{...children}</tag>`. -/
  | element : String → Array (String × Json) → Array Html → Html
  /-- Raw HTML text. -/
  | text : String → Html
  /-- A `component h e props children` represents `<Foo {...props}>{...children}</Foo>`,
  where `Foo : Component Props` is some component such that `h = hash Foo.javascript`,
  `e = Foo.«export»`, and `props` will produce a JSON-encoded value of type `Props`. -/
  | component : UInt64 → String → LazyEncodable Json → Array Html → Html
  deriving Inhabited, RpcEncodable

def Html.ofComponent [RpcEncodable Props]
    (c : Component Props) (props : Props) (children : Array Html) : Html :=
  .component (hash c.javascript) c.export (rpcEncode props) children

/-- See [MDN docs](https://developer.mozilla.org/en-US/docs/Web/CSS/CSS_Flow_Layout/Block_and_Inline_Layout_in_Normal_Flow). -/
inductive LayoutKind where
  | block
  | inline

namespace Jsx
open Parser PrettyPrinter

declare_syntax_cat jsxElement
declare_syntax_cat jsxChild
declare_syntax_cat jsxAttr
declare_syntax_cat jsxAttrVal

-- See https://leanprover.zulipchat.com/#narrow/stream/270676-lean4/topic/expected.20parser.20to.20return.20exactly.20one.20syntax.20object
-- def jsxAttrVal : Parser := strLit <|> group ("{" >> termParser >> "}")
scoped syntax str : jsxAttrVal
/-- Interpolates an expression into a JSX attribute literal -/
scoped syntax group("{" term "}") : jsxAttrVal
scoped syntax ident "=" jsxAttrVal : jsxAttr
/-- Interpolates an array of expressions into a JSX attribute literal -/
scoped syntax group("{..." term "}") : jsxAttr

-- JSXTextCharacter : SourceCharacter but not one of {, <, > or }
/-- A plain text literal for JSX (notation for `Html.text`). -/
def jsxText : Parser :=
  withAntiquot (mkAntiquot "jsxText" `ProofWidgets.Jsx.jsxText) {
    fn := fun c s =>
      let startPos := s.pos
      let s := takeWhile1Fn (not ∘ "{<>}$".contains) "expected JSX text" c s
      mkNodeToken `ProofWidgets.Jsx.jsxText startPos c s }

def getJsxText : TSyntax ``jsxText → String
  | stx => stx.raw[0].getAtomVal

@[combinator_formatter ProofWidgets.Jsx.jsxText]
def jsxText.formatter : Formatter :=
  Formatter.visitAtom ``jsxText
@[combinator_parenthesizer ProofWidgets.Jsx.jsxText]
def jsxText.parenthesizer : Parenthesizer :=
  Parenthesizer.visitToken

scoped syntax "<" ident jsxAttr* "/>" : jsxElement
scoped syntax "<" ident jsxAttr* ">" jsxChild* "</" ident ">" : jsxElement

scoped syntax jsxText      : jsxChild
/-- Interpolates an array of elements into a JSX literal -/
scoped syntax "{..." term "}" : jsxChild
/-- Interpolates an expression into a JSX literal -/
scoped syntax "{" term "}" : jsxChild
scoped syntax jsxElement   : jsxChild

scoped syntax:max jsxElement : term

/-- Sends `#[a, b, c]` to `` `(term| $a ++ $b ++ $c)``-/
def joinArrays {m} [Monad m] [MonadRef m] [MonadQuotation m] (arr : Array Term) : m Term := do
  if h : 0 < arr.size then
    arr.foldlM (fun x xs => `($x ++ $xs)) arr[0] (start := 1)
  else
    `(#[])

/-- Collapse adjacent `inl (_ : α)`s into a `β` using `f`. -/
def foldInlsM {m} [Monad m] (arr : Array (α ⊕ β)) (f : Array α → m β) : m (Array β) := do
  let mut ret : Array β := #[]
  let mut pending_inls : Array α := #[]
  for c in arr do
    match c with
    | .inl ci =>
      pending_inls := pending_inls.push ci
    | .inr cis =>
      if pending_inls.size ≠ 0 then
        ret := ret.push <| ← f pending_inls
      pending_inls := #[]
      ret := ret.push cis
  if pending_inls.size ≠ 0 then
    ret := ret.push <| ← f pending_inls
  return ret

def transformTag (n m : Ident) (vs : Array (TSyntax `jsxAttr))
    (cs : Array (TSyntax `jsxChild)) : MacroM Term := do
  let nId := n.getId.eraseMacroScopes
  let mId := m.getId.eraseMacroScopes
  if nId != mId then
    Macro.throwErrorAt m s!"expected </{nId}>"
  let cs ← cs.mapM fun
    | `(jsxChild| $t:jsxText)    => Sum.inl <$> `(Html.text $(quote <| getJsxText t))
    | `(jsxChild| { $t })        => Sum.inl <$> pure t
    | `(jsxChild| $e:jsxElement) => Sum.inl <$> `(term| $e:jsxElement)
    | `(jsxChild| {... $t })     => Sum.inr <$> pure t
    | stx                        => Macro.throwErrorAt stx "unknown syntax"
  let vs : Array ((Ident × Term) ⊕ Term) ← vs.mapM fun
    | `(jsxAttr| $attr:ident = $s:str)      => Sum.inl <$> pure (attr, s)
    | `(jsxAttr| $attr:ident = { $t:term }) => Sum.inl <$> pure (attr, t)
    | `(jsxAttr| {... $t:term })            => Sum.inr <$> pure t
    | stx                                   => Macro.throwErrorAt stx "unknown syntax"
  let tag := toString nId

  -- collect the `...`-ed children
  let children := ← joinArrays <| ← foldInlsM cs (fun cs' => `(term| #[$cs',*]))
  -- Uppercase tags are parsed as components
  if tag.get? 0 |>.filter (·.isUpper) |>.isSome then
    let withs : Array Term ← vs.filterMapM fun
      | .inr e => return some e
      | .inl _ => return none
    let vs ← vs.filterMapM fun
      | .inl (attr, val) => return some <|
        ← `(Term.structInstField| $attr:ident := $val)
      | .inr _ => return none
    let props ← match withs, vs with
      | #[w], #[] => return w
      | _, _ => `({ $withs,* with $vs:structInstField,* })
    `(Html.ofComponent $n $props $children)
  -- Lowercase tags are parsed as standard HTML
  else
    let vs := ← joinArrays <| ← foldInlsM vs (fun vs' => do
      let vs' ← vs'.mapM (fun (k, v) =>
        `(term| ($(quote <| toString k.getId), $v)))
      `(term| #[$vs',*]))
    `(Html.element $(quote tag) $vs $children)

/-- Support for writing HTML trees directly, using XML-like angle bracket syntax. It works very
similarly to [JSX](https://react.dev/learn/writing-markup-with-jsx) in JavaScript. The syntax is
enabled using `open scoped ProofWidgets.Jsx`.

Lowercase tags are interpreted as standard HTML whereas uppercase ones are expected to be
`ProofWidgets.Component`s. -/
macro_rules
  | `(<$n:ident $[$attrs:jsxAttr]* />) => transformTag n n attrs #[]
  | `(<$n:ident $[$attrs:jsxAttr]* >$cs*</$m>) => transformTag n m attrs cs

section delaborator

open Lean Delaborator SubExpr

/-- Delaborate the elements of a list literal separately, calling `elem` on each. -/
partial def delabListLiteral {α} (elem : DelabM α) : DelabM (List α) := do
  match_expr ← getExpr with
  | List.nil _ => return []
  | List.cons _ _ _ =>
    return (← withNaryArg 1 elem) :: (← withNaryArg 2 (delabListLiteral elem))
  | _ => failure


/-- Delaborate the elements of a list literal separately, calling `elem` on each. -/
partial def delabArrayLiteral {α} (elem : DelabM α) : DelabM (Array α) := do
  match_expr ← getExpr with
  | List.toArray _ _ => List.toArray <$> (withNaryArg 1 <| delabListLiteral elem)
  | _ => failure

/-- A copy of `Delaborator.annotateTermLikeInfo` for other categories. -/
def annotateTermLikeInfo (stx : TSyntax n) : DelabM (TSyntax n) := do
  let stx ← annotateCurPos ⟨stx⟩
  addTermInfo (← getPos) stx (← getExpr)
  pure ⟨stx⟩

/-- A copy of `Delaborator.withAnnotateTermLikeInfo` for other categories. -/
def withAnnotateTermLikeInfo (d : DelabM (TSyntax n)) : DelabM (TSyntax n) := do
  let stx ← d
  annotateTermLikeInfo stx

/-! First delaborate into our non-term `TSyntax`. Note this means we can't call `delab`,
so we have to add the term annotations ourselves. -/

partial def delabHtmlText : DelabM (TSyntax ``jsxText) := do
  let_expr Html.text e := ← getExpr | failure
  let .lit (.strVal s) := e | failure
  if s.any "{<>}$".contains then
    failure
  let txt ← annotateTermLikeInfo <| mkNode ``jsxText #[mkAtom s]
  return ← `(jsxText| $txt)

mutual

partial def delabHtmlElement' : DelabM (TSyntax `jsxElement) := do
  let_expr Html.element tag _attrs _children := ← getExpr | failure

  let .lit (.strVal s) := tag | failure
  let tag ← withNaryArg 0 <| annotateTermLikeInfo <| mkIdent s

  let attrs ← withNaryArg 1 <|
    try
      delabArrayLiteral <| withAnnotateTermLikeInfo do
        let_expr Prod.mk _ _ a _v := ← getExpr | failure
        let .lit (.strVal a) := a | failure
        let attr ← withNaryArg 2 <| annotateTermLikeInfo <| mkIdent a
        let v ← withNaryArg 3 delab
        `(jsxAttr| $attr:ident={ $v })
    catch _ =>
      let vs ← delab
      return #[← `(jsxAttr| {... $vs })]

  let children ← withAppArg delabJsxChildren
  if children.isEmpty then
    `(jsxElement| < $tag $[$attrs]* />)
  else
    `(jsxElement| < $tag $[$attrs]* > $[$children]* </ $tag >)

partial def delabHtmlOfComponent' : DelabM (TSyntax `jsxElement) := do
  let_expr Html.ofComponent _Props _inst _c _props _children := ← getExpr | failure
  let c ← withNaryArg 2 delab
  unless c.raw.isIdent do failure
  let tag : Ident := ⟨c.raw⟩

  -- TODO: handle `Props` that do not delaborate to `{ }`, such as `Prod`, by parsing the `Expr`
  -- instead.
  let `(term| { $[$ns:ident := $vs],* } ) ← withNaryArg 3 delab | failure
  let attrs : Array (TSyntax `jsxAttr) ← ns.zip vs |>.mapM fun (n, v) => do
    `(jsxAttr| $n:ident={ $v })

  let children ← withNaryArg 4 delabJsxChildren
  if children.isEmpty then
    `(jsxElement| < $tag $[$attrs]* />)
  else
    `(jsxElement| < $tag $[$attrs]* > $[$children]* </ $tag >)

partial def delabJsxChildren : DelabM (Array (TSyntax `jsxChild)) := do
  try
    delabArrayLiteral (withAnnotateTermLikeInfo do
      try
        match_expr ← getExpr with
        | Html.text _ =>
          let html ← delabHtmlText
          return ← `(jsxChild| $html:jsxText)
        | Html.element _ _ _ =>
          let html ← delabHtmlElement'
          return ← `(jsxChild| $html:jsxElement)
        | Html.ofComponent _ _ _ _ _ =>
          let comp ← delabHtmlOfComponent'
          return ← `(jsxChild| $comp:jsxElement)
        | _ => failure
      catch _ =>
        let fallback ← delab
        return ← `(jsxChild| { $fallback }))
  catch _ =>
    let fallback ← delab
    return #[⟨← `(ohno)⟩]
    -- return #[← `(jsxChild| {... $fallback })]

end

/-! Now wrap our `TSyntax _` delaborators into `Term` elaborators. -/

@[delab app.ProofWidgets.Html.element]
def delabHtmlElement : Delab := do
  let t ← delabHtmlElement'
  `(term| $t:jsxElement)

@[delab app.ProofWidgets.Html.ofComponent]
def delabHtmlOfComponent : Delab := do
  let t ← delabHtmlOfComponent'
  `(term| $t:jsxElement)

end delaborator

end Jsx
end ProofWidgets
