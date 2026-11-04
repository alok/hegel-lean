import Tests.FuzzHarness

def main (args : List String) : IO UInt32 := do
  let start := (args[0]? >>= String.toNat?).getD 0
  let count := (args[1]? >>= String.toNat?).getD 200
  let examples := (args[2]? >>= String.toNat?).getD 100
  let machines := args[3]? == some "machines"
  let mut bugs := 0
  let mut tally : Std.HashMap String Nat := {}
  for seed in [start:start + count] do
    let verdict ← if machines then Tests.FuzzHarness.runMachine seed examples
      else Tests.FuzzHarness.runOne seed examples
    match verdict with
    | .ok kind => tally := tally.insert kind (tally.getD kind 0 + 1)
    | .bug detail =>
      bugs := bugs + 1
      IO.println s!"BUG seed={seed}: {detail}\n"
  IO.println s!"{count} programs: {tally.toList}, {bugs} bugs"
  return if bugs == 0 then 0 else 1
