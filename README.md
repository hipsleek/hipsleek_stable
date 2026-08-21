# HIP/SLEEK

HIP/SLEEK is an automated program verification framework based on **separation
logic**. It consists of two tools that share the same specification language and
proof engine:

- **SLEEK** — a standalone *separation logic entailment checker*. Given user-defined
  inductive heap predicates, it decides entailments of the form
  `antecedent |- consequent` (`.slk` files).
- **HIP** — a *program verifier* for an imperative, heap-manipulating language.
  Procedures are annotated with `requires`/`ensures` pre- and post-conditions;
  HIP discharges the resulting proof obligations via SLEEK (`.ss` files).

Proof obligations that are not pure separation logic are handed off to external
provers: **Z3** and **Omega** (arithmetic), **Mona** (sets/second-order),
**Redlog** (non-linear arithmetic) and **Fixcalc** (fixpoint computation).

## Examples

A SLEEK entailment over a singly linked list predicate
([`dune-tests/sleek/sleek10.t/sleek10.slk`](dune-tests/sleek/sleek10.t/sleek10.slk)):

```
data node { int val ; node next }.

pred ll<n> == self = null & n = 0
         or self::node<_,r> * r::ll<n - 1>
         inv n >= 0.

checkentail x::ll<n> & x!=null |- x::ll<m> & m>0.   // Valid
checkentail x::ll<n>           |- x::ll<m> & m>0.   // Fail
```

```console
$ dune exec ./sleek.exe -- dune-tests/sleek/sleek10.t/sleek10.slk
Entail 1: Valid.
Entail 2: Fail.(may) cause:base case unfold failed
```

A HIP-verified procedure, appending two lists while tracking their lengths
([`dune-tests/hip/ll.t/ll.ss`](dune-tests/hip/ll.t/ll.ss)):

```c
void append2(node x, node y)
  requires x::ll<n1> * y::ll<n2> & n1>0
  ensures x::ll<n1+n2>;
{
  if (x.next == null)
    x.next = y;
  else
    append2(x.next, y);
}
```

```console
$ dune exec ./hip.exe -- dune-tests/hip/ll.t/ll.ss
...
Procedure append2$node~node SUCCESS.
```

## Quickstart

Full installation instructions — opam and OCaml setup, plus building the external
provers — are in the [install guide](docs/src/install.md)
([online version](https://hipsleek.github.io/hipsleek/install.html)). The short
version:

```sh
opam install . --deps-only    # OCaml dependencies
dune build @hipsleek          # builds hip.exe, sleek.exe and the preludes
dune test                     # runs the test suite
```

Running the tools needs **Z3** and **Omega** on your `PATH`. Mona, Redlog and
Fixcalc are optional — tests that need them are skipped when they are not found.

SLEEK can also be used as an OCaml library (`hipsleek.api`, see [`api/`](api/)),
installed with `opam install .`.

## Development

### Where the tests live

| Location | Kind | What it covers |
|----------|------|----------------|
| [`dune-tests/sleek/`](dune-tests/sleek) | dune [cram tests](https://dune.readthedocs.io/en/stable/reference/cram.html) | SLEEK entailments — each `foo.t/` holds a `.slk` file and the expected `Entail N: Valid/Fail` output in `run.t` |
| [`dune-tests/hip/`](dune-tests/hip) | cram tests | HIP verification — each `foo.t/` holds a `.ss` file and the expected `Procedure NAME SUCCESS` lines |
| [`dune-tests/hip/redlog/`](dune-tests/hip/redlog) | cram tests | ParaHIP and friends; skipped with a warning when `redcsl` is absent |
| [`api/sleekapi_tests.ml`](api/sleekapi_tests.ml) | `ppx_expect` inline tests | the OCaml API |

Raw prover output is noisy, so cram tests pipe it through the filters in
[`dune-tests/test_assets/`](dune-tests/test_assets) (`sleek_postprocess.sh`,
`hip_postprocess.sh`) before comparing.

```sh
dune test                                    # everything
dune build @dune-tests/sleek/runtest         # just the SLEEK cram tests
dune test dune-tests/hip/ll.t                # a single test directory
dune test --auto-promote                     # accept new output (review the diff!)
```

`scripts/local-ci.sh` runs the build and test steps and reports which optional
provers are missing. The GitHub Actions workflow
([`.github/workflows/test.yml`](.github/workflows/test.yml)) invokes this same
script, so a local run and a CI run cannot drift apart:

```sh
./scripts/local-ci.sh                          # full run, gated (see below)
./scripts/local-ci.sh dune-tests/hip/ll.t      # one target, dune's verdict only
```

#### Known test failures

`dune test` does not currently pass on master. The stale baselines have **not**
been promoted — that would rewrite known-bad output into `run.t` as if it were
expected. Instead the failing targets are recorded in
[`scripts/known-test-failures.txt`](scripts/known-test-failures.txt), and a full
`local-ci.sh` run compares against it:

| Situation | Result |
|---|---|
| Failing set matches the list | passes |
| A target fails that is not listed | **fails** — a new regression |
| A listed target passes | **fails** — delete its line from the list |

So the gate blocks new regressions today, while the existing divergences stay
visible as a to-do list rather than being buried. Each entry is triaged in
[`CLAUDE.md`](CLAUDE.md) under "dune test baseline".

### Code formatting

The repository has an `.ocamlformat` file, but formatting is **disabled by
default** (`disable=true`) — reformatting the tree wholesale would destroy
history on a large legacy codebase (see issue #48). To opt in for new code, add
`disable=false` to a `.ocamlformat` in that directory, or list individual files
in `.ocamlformat-enable`.

### Documentation

The docs under [`docs/`](docs) are an [mdBook](https://rust-lang.github.io/mdBook/);
pushes to `master` that touch `docs/**` publish to
<https://hipsleek.github.io/hipsleek/>.

```sh
cd docs && mdbook serve
```




