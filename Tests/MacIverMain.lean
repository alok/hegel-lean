import Tests.MacIver

/-- Optional receipt path, followed by any seeds to run; default seeds are 0, 1, and 42. -/
def main (args : List String) : IO Unit := do
  let seeds ← args.drop 1 |>.toArray.mapM fun arg =>
    match arg.toNat? with
    | some n => if n < 2^64 then pure n.toUInt64 else throw (IO.userError "Seed exceeds UInt64")
    | none => throw (IO.userError s!"Invalid seed: {arg}")
  let receipts ← Tests.MacIver.run (if seeds.isEmpty then #[0, 1, 42] else seeds)
  if let some output := args.head? then
    Tests.MacIver.writeReceipts output receipts
