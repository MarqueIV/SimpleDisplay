import XCTest
@testable import SimpleDisplayCore

final class GhostReconcilerTests: XCTestCase {

    private typealias Ghost = GhostReconciler.Ghost
    private typealias Live = GhostReconciler.Live

    private func noResolve(_: String) -> UInt32? { nil }

    // MARK: - Back online

    func testGhostWhoseUUIDIsLiveIsBackOnline() {
        let verdicts = GhostReconciler.reconcile(
            ghosts: [Ghost(uuid: "A", id: 5)],
            live: [Live(uuid: "A", id: 9)],
            resolveID: noResolve
        )
        XCTAssertEqual(verdicts["A"], .backOnline)
    }

    func testBackOnlineWinsEvenIfRetainedIDNowBelongsToAnotherDisplay() {
        let verdicts = GhostReconciler.reconcile(
            ghosts: [Ghost(uuid: "A", id: 5)],
            live: [Live(uuid: "A", id: 9), Live(uuid: "B", id: 5)],
            resolveID: noResolve
        )
        XCTAssertEqual(verdicts["A"], .backOnline)
    }

    // MARK: - Keep

    func testGhostIsKeptWithRetainedIDWhenNothingCollides() {
        let verdicts = GhostReconciler.reconcile(
            ghosts: [Ghost(uuid: "A", id: 5)],
            live: [Live(uuid: "B", id: 1), Live(uuid: "C", id: 2)],
            resolveID: noResolve
        )
        XCTAssertEqual(verdicts["A"], .keep(id: 5))
    }

    func testGhostIsReaddressedWhenUUIDResolvesToFreshID() {
        let verdicts = GhostReconciler.reconcile(
            ghosts: [Ghost(uuid: "A", id: 5)],
            live: [Live(uuid: "B", id: 1)],
            resolveID: { $0 == "A" ? 77 : nil }
        )
        XCTAssertEqual(verdicts["A"], .keep(id: 77))
    }

    func testResolvedIDIsUsedEvenWhenRetainedIDCollides() {
        // Retained ID 5 now belongs to B, but the UUID resolves to a free ID,
        // so the ghost stays addressable.
        let verdicts = GhostReconciler.reconcile(
            ghosts: [Ghost(uuid: "A", id: 5)],
            live: [Live(uuid: "B", id: 5)],
            resolveID: { _ in 77 }
        )
        XCTAssertEqual(verdicts["A"], .keep(id: 77))
    }

    // MARK: - Collisions

    func testGhostCollidesWhenRetainedIDBelongsToAnotherLiveDisplay() {
        let verdicts = GhostReconciler.reconcile(
            ghosts: [Ghost(uuid: "A", id: 5)],
            live: [Live(uuid: "B", id: 5)],
            resolveID: noResolve
        )
        XCTAssertEqual(verdicts["A"], .collided(withLiveUUID: "B"))
    }

    func testGhostCollidesWithLiveDisplayThatHasNoUUID() {
        let verdicts = GhostReconciler.reconcile(
            ghosts: [Ghost(uuid: "A", id: 5)],
            live: [Live(uuid: nil, id: 5)],
            resolveID: noResolve
        )
        XCTAssertEqual(verdicts["A"], .collided(withLiveUUID: nil))
    }

    func testResolvedIDOwnedByAnotherLiveDisplayIsStillACollision() {
        let verdicts = GhostReconciler.reconcile(
            ghosts: [Ghost(uuid: "A", id: 5)],
            live: [Live(uuid: "B", id: 77)],
            resolveID: { _ in 77 }
        )
        XCTAssertEqual(verdicts["A"], .collided(withLiveUUID: "B"))
    }

    // MARK: - Shape

    func testEmptyGhostsProduceNoVerdicts() {
        let verdicts = GhostReconciler.reconcile(
            ghosts: [],
            live: [Live(uuid: "B", id: 1)],
            resolveID: noResolve
        )
        XCTAssertTrue(verdicts.isEmpty)
    }

    func testEmptyLiveListKeepsEveryGhost() {
        let verdicts = GhostReconciler.reconcile(
            ghosts: [Ghost(uuid: "A", id: 5), Ghost(uuid: "B", id: 6)],
            live: [],
            resolveID: noResolve
        )
        XCTAssertEqual(verdicts["A"], .keep(id: 5))
        XCTAssertEqual(verdicts["B"], .keep(id: 6))
    }

    func testGhostsAreJudgedIndependently() {
        let verdicts = GhostReconciler.reconcile(
            ghosts: [Ghost(uuid: "A", id: 5), Ghost(uuid: "B", id: 6), Ghost(uuid: "C", id: 7)],
            live: [Live(uuid: "A", id: 5), Live(uuid: "X", id: 6)],
            resolveID: noResolve
        )
        XCTAssertEqual(verdicts.count, 3)
        XCTAssertEqual(verdicts["A"], .backOnline)
        XCTAssertEqual(verdicts["B"], .collided(withLiveUUID: "X"))
        XCTAssertEqual(verdicts["C"], .keep(id: 7))
    }
}
