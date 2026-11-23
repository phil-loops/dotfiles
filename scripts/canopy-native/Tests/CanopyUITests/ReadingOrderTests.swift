@testable import CanopyUI
import Testing

struct ReadingOrderTests {
    private func order(_ files: [(String, Int, Int)]) -> [String] {
        ReadingOrder.sorted(files.map { NodeFile(path: $0.0, add: $0.1, del: $0.2, patch: "") }).map(\.path)
    }

    @Test func layersReadSchemaToUI() {
        // #11728 + #11729's shape, fused
        #expect(order([
            ("components/admin/ImageUploadLimit.tsx", 85, 0), ("lib/uploads/complete.ts", 6, 19),
            ("models/image-upload-limit.ts", 57, 0), ("packages/prisma/schema.prisma", 1, 0),
            ("queries/team.ts", 19, 0), ("testing/prisma/team.ts", 1, 0), ("trpc/routers/admin-router.ts", 2, 0),
        ]) == [
            "packages/prisma/schema.prisma", "queries/team.ts", "models/image-upload-limit.ts", "lib/uploads/complete.ts",
            "trpc/routers/admin-router.ts", "components/admin/ImageUploadLimit.tsx", "testing/prisma/team.ts",
        ])
    }

    @Test func aTestFollowsItsSource() {
        #expect(order([("lib/uploads/complete.test.ts", 13, 3), ("lib/uploads/complete.ts", 6, 19)]) == ["lib/uploads/complete.ts", "lib/uploads/complete.test.ts"])
    }

    @Test func deleteOnlyFilesGoLast() {
        #expect(order([("jobs/rollup.ts", 0, 222), ("jobs/index.ts", 0, 2), ("lib/process.ts", 76, 4), ("queries/rollup.ts", 0, 37)]) == ["lib/process.ts", "queries/rollup.ts", "jobs/index.ts", "jobs/rollup.ts"])
    }

    @Test func unlayeredPathsKeepPathOrder() {
        let paths = ["components/loopBuilder/DotGrid.tsx", "components/loopBuilder/LoopFlowchart.tsx", "components/loopBuilder/viewportBoundsMath.ts"]
        #expect(order(paths.reversed().map { ($0, 1, 1) }) == paths)
    }

    @Test func apiRoutesAreWiringOtherPagesAreUI() {
        #expect(order([("pages/settings.tsx", 1, 0), ("pages/api/domains/update.ts", 1, 0)]) == ["pages/api/domains/update.ts", "pages/settings.tsx"])
    }
}
