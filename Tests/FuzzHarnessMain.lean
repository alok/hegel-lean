import Tests.FuzzHarness

def main (args : List String) : IO UInt32 := do
  let start := (args[0]? >>= String.toNat?).getD 0
  let count := (args[1]? >>= String.toNat?).getD 200
  let examples := (args[2]? >>= String.toNat?).getD 100
  let machines := args[3]? == some "machines"
  let mut bugs := 0
  let mut passed := 0
  let mut replayed := 0
  let mut exhausted := 0
  for seed in [start:start + count] do
    let verdict ← if machines then Tests.FuzzHarness.runMachine seed examples
      else Tests.FuzzHarness.runOne seed examples
    match verdict with
    | .passed => passed := passed + 1
    | .replayed => replayed := replayed + 1
    | .exhausted => exhausted := exhausted + 1
    | .bug detail =>
      bugs := bugs + 1
      IO.println s!"BUG seed={seed}: {detail}\n"
  IO.println s!"{count} programs: {passed} passed, {replayed} failed and replayed, {exhausted} exhausted, {bugs} bugs"
  return if bugs == 0 && passed + replayed > 0 then 0 else 1
