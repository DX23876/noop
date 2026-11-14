import XCTest
@testable import StrandDesign

final class AppGroupResolverTests: XCTestCase {
    private let configured = "group.com.noopapp.noop.staging"

    private func granted(_ groups: String...) -> (String) -> Bool {
        let set = Set(groups)
        return { set.contains($0) }
    }

    func testXcodeBuildUsesConfiguredGroupWhenGranted() {
        XCTAssertEqual(
            AppGroupResolver.resolve(info: ["AppGroupIdentifier": configured],
                                     isGranted: granted(configured)),
            configured)
    }

    func testAltStoreTeamSuffixedGroupWins() {
        let remapped = configured + ".TEAM123456"
        XCTAssertEqual(
            AppGroupResolver.resolve(info: ["AppGroupIdentifier": configured, "ALTAppGroups": [remapped]],
                                     isGranted: granted(remapped)),
            remapped)
    }

    /// SideStore "Keep App Extensions (Use Main Profile)": only the app's Info.plist lists ALTAppGroups.
    func testExtensionFollowsContainingAppAltStoreGroups() {
        let remapped = configured + ".TEAM123456"
        let app = AppGroupResolver.resolve(
            info: ["AppGroupIdentifier": configured, "ALTAppGroups": [remapped]],
            isGranted: granted(remapped))
        let widget = AppGroupResolver.resolve(
            info: ["AppGroupIdentifier": configured],
            containingAppInfo: ["AppGroupIdentifier": configured, "ALTAppGroups": [remapped]],
            isGranted: granted(remapped))
        XCTAssertEqual(app, remapped)
        XCTAssertEqual(widget, app)
    }

    /// A certificate seller's profile (Feather, neostore, Signulous) grants its own fixed groups.
    func testSellerProfileGroupsGiveAppAndWidgetTheSameGroup() {
        let groups = ["group.abc123.5", "group.abc123.3", "group.abc123.1", "group.abc123.2", "group.abc123.4"]
        let isGranted: (String) -> Bool = { groups.contains($0) }
        let app = AppGroupResolver.resolve(info: ["AppGroupIdentifier": configured],
                                           profileGroups: groups, isGranted: isGranted)
        let widget = AppGroupResolver.resolve(info: ["AppGroupIdentifier": configured],
                                              containingAppInfo: ["AppGroupIdentifier": configured],
                                              profileGroups: groups.reversed(), isGranted: isGranted)
        XCTAssertEqual(app, "group.abc123.1")
        XCTAssertEqual(widget, app)
    }

    func testProfileGroupThatIsNotGrantedIsSkipped() {
        XCTAssertEqual(
            AppGroupResolver.resolve(info: ["AppGroupIdentifier": configured],
                                     profileGroups: ["group.a.1", "group.a.2"],
                                     isGranted: granted("group.a.2")),
            "group.a.2")
    }

    func testNothingGrantedKeepsBuildTimeRule() {
        XCTAssertEqual(
            AppGroupResolver.resolve(info: ["AppGroupIdentifier": configured],
                                     profileGroups: ["group.a.1"], isGranted: { _ in false }),
            configured)
        XCTAssertEqual(AppGroupResolver.resolve(info: [:], isGranted: { _ in false }),
                       AppGroupResolver.fallbackGroup)
    }

    func testBuildTimeRuleWithoutProbe() {
        XCTAssertEqual(AppGroupResolver.resolve(info: ["ALTAppGroups": ["group.x.TEAM"]]), "group.x.TEAM")
        XCTAssertEqual(
            AppGroupResolver.resolve(info: ["AppGroupIdentifier": "group.x",
                                            "ALTAppGroups": ["group.a", "group.b"]]),
            "group.x")
    }

    func testProfileParserReadsGroupsFromCMSWrappedPlist() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>Entitlements</key><dict>
        <key>com.apple.security.application-groups</key>
        <array><string>group.abc.2</string><string> group.abc.1 </string><string>notagroup</string></array>
        </dict></dict></plist>
        """
        var blob = Data([0x30, 0x82, 0x4C, 0x00, 0x06, 0x09])
        blob.append(Data(xml.utf8))
        blob.append(Data([0xA0, 0x82, 0x3F, 0x00]))
        let plist = try XCTUnwrap(ProvisioningProfile.plist(from: blob))
        XCTAssertEqual(ProvisioningProfile.appGroups(in: plist), ["group.abc.2", "group.abc.1"])
    }

    func testProfileParserRejectsBytesWithoutPlist() {
        XCTAssertNil(ProvisioningProfile.plist(from: Data([0x30, 0x82, 0x00])))
    }
}
