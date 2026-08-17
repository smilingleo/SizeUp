import Testing
@testable import Geometry

private let one = SpaceIdentifier(1)
private let three = SpaceIdentifier(3)
private let fortyTwo = SpaceIdentifier(288)

@Test func nextSpaceWrapsAroundToTheFirst() {
    let strip = [one, three, fortyTwo]
    #expect(neighbouringSpace(from: one, in: strip, direction: .next) == three)
    #expect(neighbouringSpace(from: three, in: strip, direction: .next) == fortyTwo)
    #expect(neighbouringSpace(from: fortyTwo, in: strip, direction: .next) == one)
}

@Test func previousSpaceWrapsAroundToTheLast() {
    let strip = [one, three, fortyTwo]
    #expect(neighbouringSpace(from: fortyTwo, in: strip, direction: .previous) == three)
    #expect(neighbouringSpace(from: three, in: strip, direction: .previous) == one)
    #expect(neighbouringSpace(from: one, in: strip, direction: .previous) == fortyTwo)
}

@Test func singleSpaceHasNoNeighbour() {
    #expect(neighbouringSpace(from: one, in: [one], direction: .next) == nil)
    #expect(neighbouringSpace(from: one, in: [one], direction: .previous) == nil)
}

@Test func emptySpaceListHasNoNeighbour() {
    #expect(neighbouringSpace(from: one, in: [], direction: .next) == nil)
}

@Test func unknownCurrentSpaceHasNoNeighbour() {
    // `current` not present in `spaces` at all — a stale or mismatched read
    // must not fall back to some arbitrary index.
    #expect(neighbouringSpace(from: SpaceIdentifier(999), in: [one, three], direction: .next) == nil)
}

@Test func aboveAndBelowAreNotSpaceDirections() {
    // No vertical neighbour has existed since Lion; these must always be nil.
    let strip = [one, three, fortyTwo]
    #expect(neighbouringSpace(from: one, in: strip, direction: .above) == nil)
    #expect(neighbouringSpace(from: one, in: strip, direction: .below) == nil)
}

@Test func spaceIdentifierDistinguishesEqualRawValuesOfDifferentSemanticKind() {
    // Not a behavioural test of neighbouringSpace, but pins the type-safety
    // goal: two SpaceIdentifiers with the same rawValue are equal, and the
    // type itself cannot be confused with a window ID or display identifier
    // at compile time (that guarantee is enforced by the type checker, not
    // observable at runtime, so this test only checks the Hashable/Equatable
    // half of the contract).
    #expect(SpaceIdentifier(1) == SpaceIdentifier(1))
    #expect(SpaceIdentifier(1) != SpaceIdentifier(2))
}
