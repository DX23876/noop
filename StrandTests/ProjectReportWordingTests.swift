import XCTest
import StrandCore
@testable import Strand

/// A send that did not go out says WHICH of the four reasons it was.
///
/// Before this, every cause reached the reporter as one sentence, "that did not go out, try again
/// later": a switch they threw themselves, a rate limit that waiting actually fixes, a service that
/// answered no, and a connection that is not there. A tester hit it, and neither they nor anybody
/// reading over their shoulder could tell which had happened, because the screen said less than the
/// core already knew.
///
/// The reason is decided ONCE, in `StrandCore.ProjectService.failure`; this is only its wording, and
/// the report form and the thread both read it here so they cannot word one cause differently. The
/// Kotlin twin is `ProjectReportWordingTest`.
final class ProjectReportWordingTests: XCTestCase {
    /// Every reason the core can name has a sentence, and no two reasons share one. `CaseIterable`
    /// rather than a written-out list on purpose: a fifth reason added to the core fails here until
    /// somebody decides what it says, instead of quietly reading as one of the other four.
    func testEveryReasonHasASentenceOfItsOwn() {
        let sentences = ProjectWriteFailure.allCases.map(ProjectReportWording.sentence)
        XCTAssertEqual(sentences.count, 4, "the core's reasons")
        XCTAssertEqual(Set(sentences).count, sentences.count, "two reasons share a sentence")
        for sentence in sentences {
            XCTAssertFalse(sentence.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    /// The old sentence is gone from this path. It is the one thing a regression here would bring
    /// back, and it reads as plausible, which is why it survived as long as it did.
    func testNoReasonStillSaysTheOldSentence() {
        for why in ProjectWriteFailure.allCases {
            XCTAssertNotEqual(ProjectReportWording.sentence(why), "That did not go out. Try again later.")
        }
    }

    /// Switched off is not a network problem and must not be worded as a wait. This is the case that
    /// sent people to their connection settings over a switch sitting on the screen they came from.
    func testSwitchedOffDoesNotBlameTheNetworkOrAskForAWait() {
        let sentence = ProjectReportWording.sentence(.notSending).lowercased()
        XCTAssertTrue(sentence.contains("switched off"), sentence)
        XCTAssertFalse(sentence.contains("try again"), "waiting does not fix a switch")
        XCTAssertFalse(ProjectReportWording.sentence(.tooMany).lowercased().contains("switched off"))
    }
}
