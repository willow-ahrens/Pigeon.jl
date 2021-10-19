using Pigeon
using Pigeon: ListFormat, ArrayFormat, HashFormat
using Pigeon: StepProtocol, LocateProtocol, AppendProtocol, InsertProtocol

using Pigeon: Direct

A = Direct(Fiber(:A, [ArrayFormat(), ArrayFormat()], [:I, :J]), [LocateProtocol(), LocateProtocol()])
B = Fiber(:B, [ArrayFormat(), ListFormat()], [:I, :J])
B1 = Direct(B, [LocateProtocol(), StepProtocol()])
B2 = Direct(B, [LocateProtocol(), LocateProtocol()])

prg = @i @∀ i (
	@∀ j (
		A[i, j] += B1[i, j] * B2[i, j]
    )
)

println(Pigeon.transform_reformat(prg))