/*
  Bug: implicit bind for ref field-access arguments (src/astsimp.ml)

  When a `ref` parameter is passed a field-access expression like `x.next`,
  the translator used to emit a C.Bind with read_only=true (no write-back).
  After the callee returned, the updated value was only in a fresh existential
  variable disconnected from the node cell x::node<_,q>, so predicate folding
  to x::ls<null> failed.

  Fix: In the CallNRecv handler, detect any ref parameter receiving an
  I.Member{base=I.Var, fields=[f]} argument and rewrite the call as an explicit
  I.Bind wrapping the I.CallNRecv, replacing the I.Member arg with a fresh
  I.Var.  The I.Bind handler then generates a C.Bind with read_only=false,
  enabling the write-back that re-establishes the node-field connection.

  Buggy version: append (below) — previously failed because x.next was
  translated with read_only=true, blocking the predicate fold.

  Working workaround: append3 (below) — used an explicit
    bind x to (_,s) in { append3(s, y); }
  which went through I.Bind directly with read_only=false.

  After the fix both functions verify successfully.
*/

data node {
  int val;
  node next;
}

ls<y> == self=y
  or self::node<_,q>*q::ls<y> & self!=y
inv true;

/* Previously FAILED: x.next passed to ref param with read_only=true */
void append(ref node x, node y)
  requires x::ls<null>*y::ls<null>
  ensures x'::ls<null>; //'
{
  if (x==null) {
    x = y;
  } else {
    append(x.next, y);
  }
}

/* Workaround that always worked: explicit bind gives read_only=false */
void append3(ref node x, node y)
  requires x::ls<null>*y::ls<null>
  ensures x'::ls<null>; //'
{
  if (x==null) {
    x = y;
  } else {
    bind x to (_,s) in {
      append3(s, y);
    }
  }
}
