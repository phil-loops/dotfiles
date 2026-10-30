/// Every page area, installed in this order at launch. Pre-populated with all of them so no porter
/// edits this file: each area's `install` lives in its own folder (Pages/<Area>/<Area>Area.swift).
@MainActor
enum Areas {
    static let all: [PageArea.Type] = [
        ForestsArea.self,
        ReviewArea.self,
        ShipArea.self,
        TutorArea.self,
        MachineArea.self,
        WikiArea.self,
        TodoArea.self,
        PaletteArea.self,
        KeyTutorArea.self,
    ]
}
