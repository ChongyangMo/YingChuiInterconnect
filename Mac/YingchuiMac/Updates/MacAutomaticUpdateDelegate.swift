import AppKit
import Sparkle
import YingchuiProtocol

extension MacUpdateController {
    func feedURLString(for updater: SPUUpdater) -> String? { configuration?.feedURL.absoluteString }
    func allowedChannels(for updater: SPUUpdater) -> Set<String> { [] }
    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }
    func standardUserDriverShouldShowVersionHistory(for item: SUAppcastItem) -> Bool { false }
    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate item: SUAppcastItem) -> Bool { false }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard automaticUpdatesEnabled, !hasDeferredInstallation, !installationCommitted else {
            throw MacManagementError.updateCancelled
        }
        sessionID = UUID()
        target = nil
        state = .checking
    }

    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        guard sessionIsCurrent, let url = item.fileURL, !item.isInformationOnlyUpdate,
              let minimum = item.minimumSystemVersion,
              MacBuildNumber.isAtLeast(MacUpdateSourcePolicy.osVersion, minimum) else {
            throw MacManagementError.response
        }
        if let maximum = item.maximumSystemVersion,
           !MacBuildNumber.isAtLeast(maximum, MacUpdateSourcePolicy.osVersion) { throw MacManagementError.response }
        let releaseID = url.deletingLastPathComponent().lastPathComponent
        let proposed = MacAutomaticUpdateTarget(release: MacAvailableUpdate(
            release_id: releaseID, app_version: item.displayVersionString, app_build: item.versionString,
            appcast_url: MacUpdateSourcePolicy.fixedFeed(releaseID: releaseID)), artifactURL: url, size: item.contentLength)
        try proposed.validate(currentBuild: currentBuild)
        if let target, target != proposed { throw MacManagementError.response }
        target = proposed
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        if sessionIsCurrent { state = .available }
    }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        state = completion?.state(currentBuild: currentBuild) == .installed ? .installed : .idle
    }
    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        if sessionIsCurrent { state = .downloading }
    }
    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        if sessionIsCurrent { state = .downloaded }
    }
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        if sessionIsCurrent { log.record("更新包已通过组件校验，等待空闲安装") }
    }
    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool { true }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        guard !stopping else { return }
        let value = error as NSError
        if value.domain == SUSparkleErrorDomain, value.code == Int(SUError.noUpdateError.rawValue) {
            updaterDidNotFindUpdate(updater)
            return
        }
        if error as? MacManagementError == .updateCancelled { return }
        fail(error)
    }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        guard !hasDeferredInstallation, !installationCommitted else { return }
        sessionID = nil
        target = nil
        userDriver?.cancelCurrentInteraction()
    }
    func userDidCancelDownload(_ updater: SPUUpdater) { fail(MacManagementError.updateCancelled) }
}
