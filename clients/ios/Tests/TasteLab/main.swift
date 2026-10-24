import Foundation
var session = TasteLabSession()
assert(session.answers.isEmpty && !session.complete)
session.choose(.a)
assert(session.dimension == .furniture)
session.choose(.both)
assert(session.complete && session.suggestedFocus == "Lighting")
assert(session.interpretation.contains("better starting point than furniture"))
assert(session.brief(for: "Lighting").contains("lamp"))
session.undo()
assert(!session.complete && session.answers.count == 1)
session.choose(.b)
assert(session.interpretation.contains("Both may matter"))
for first in TasteLabSession.Choice.allCases {
    for second in TasteLabSession.Choice.allCases {
        var trial = TasteLabSession()
        trial.choose(first); trial.choose(second); trial.choose(.a)
        assert(trial.answers.count == 2)
        if (first == .both || first == .neither) && (second == .both || second == .neither) {
            assert(trial.suggestedFocus.isEmpty && trial.brief(for: trial.suggestedFocus).isEmpty)
        }
        trial.undo(); trial.undo(); trial.undo()
        assert(trial.answers.isEmpty)
    }
}
assert(TasteLabSession().answers.isEmpty)
print("Taste Lab: 16 choice combinations, undo, ambiguous choices and new-session isolation passed")

assert(TasteLabSession.productType(for: "Find a reading lamp for a softly lit, warm reading corner") == "lamp")
assert(TasteLabSession.productType(for: "Find an upholstered reading chair for a relaxing reading corner") == "chair")
assert(TasteLabSession.productType(for: "Something else") == nil)

assert(!TasteLabSession.suitableTitle("Kids gaming recliner", for: "chair"))
assert(TasteLabSession.suitableTitle("Upholstered accent chair", for: "chair"))
assert(!TasteLabSession.suitableTitle("Dining Chair", for: "chair"))
assert(TasteLabSession.suitableTitle("Floor lamp with reading light", for: "lamp"))
