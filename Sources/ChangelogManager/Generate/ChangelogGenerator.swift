import ArgumentParser
import Files
import Foundation
import Version
import Yams

struct ChangelogGenerator {
  private struct ReleaseEntry {
    let version: Version
    let entries: [ChangelogEntry]
  }

  func regenerateChangelogs() throws {
    guard
      let configString = try? Folder.current.file(named: ".changelog-manager.yml").readAsString()
    else {
      throw ValidationError("No config found.")
    }

    let decoder = YAMLDecoder()
    guard let config = try? decoder.decode(ChangelogManagerConfig.self, from: configString) else {
      throw ValidationError("Invalid config file format.")
    }

    let releaseEntries = try getReleaseEntries(decoder: decoder)
    let sortedReleaseEntries = releaseEntries.sorted { $0.version > $1.version }
    let unreleasedEntries = try getUnreleasedEntries(decoder: decoder)

    for file in config.files {
      try writeToChangelog(
        unreleasedEntries: unreleasedEntries,
        releaseEntries: sortedReleaseEntries,
        file: file
      )
    }
  }

  private func getReleaseEntries(decoder: YAMLDecoder) throws -> [ReleaseEntry] {
    var releaseEntries = [ReleaseEntry]()
    var error: Error?
    let queue = DispatchQueue(
      label: "com.swiftbuildtools.changelog-manager.thread-safe-array",
      qos: .userInitiated,
      attributes: .concurrent
    )
    let group = DispatchGroup()
    let releaseFolders = try Folder.current.createSubfolderIfNeeded(
      at: ".changelog-manager/releases"
    ).subfolders

    for releaseFolder in releaseFolders {
      DispatchQueue.global(qos: .userInitiated).async(group: group) {
        do {
          let releaseVersion = try self.getVersion(for: releaseFolder, decoder: decoder)
          let preReleaseFolders = try releaseFolder
            .subfolders
            .filter { $0.name != "entries" }
            .map { (version: try self.getVersion(for: $0, decoder: decoder), folder: $0) }
            .sorted {
              $0.version < $1.version
            }
            .map(\.folder)

          let entryFolders = preReleaseFolders + [releaseFolder]
          let entries = try entryFolders.flatMap {
            try self.changelogEntries(
              folder: $0.createSubfolderIfNeeded(at: "entries"),
              decoder: decoder
            ).sorted {
              $0.createdAtDate < $1.createdAtDate
            }
          }

          queue.sync(flags: .barrier) {
            releaseEntries.append(.init(version: releaseVersion, entries: entries))
          }
        }
        catch let e {
          queue.sync(flags: .barrier) {
            error = e
          }
        }
      }
    }

    group.wait()

    if let error = error {
      throw error
    }

    return releaseEntries
  }

  private func getVersion(for folder: Folder, decoder: YAMLDecoder) throws -> Version {
    let releaseInfoString = try folder.file(named: "info.yml").readAsString()
    return try decoder.decode(ReleaseInfo.self, from: releaseInfoString).version
  }

  private func getUnreleasedEntries(decoder: YAMLDecoder) throws -> [ChangelogEntry] {
    let unreleasedFolder = try Folder.current.createSubfolderIfNeeded(
      at: ".changelog-manager/Unreleased"
    )
    return try changelogEntries(folder: unreleasedFolder, decoder: decoder).sorted {
      $0.createdAtDate < $1.createdAtDate
    }
  }

  private func changelogEntries(folder: Folder, decoder: YAMLDecoder) throws -> [ChangelogEntry] {
    return try folder.files.map { file in
      let fileString = try file.readAsString()
      return try decoder.decode(ChangelogEntry.self, from: fileString)
    }
  }

  private func writeToChangelog(
    unreleasedEntries: [ChangelogEntry],
    releaseEntries: [ReleaseEntry],
    file: ChangelogManagerConfig.ChangelogFile
  ) throws {
    let unreleasedContentString = sectionString(
      name: "Unreleased",
      entries: unreleasedEntries,
      file: file
    )

    let releaseContentString = releaseEntries.map { releaseEntry in
      sectionString(
        name: releaseEntry.version.description,
        entries: releaseEntry.entries,
        file: file
      )
    }.joined(separator: "\n\n\n")

    let changelogString =
      """
      # Changelog
      All notable changes to this project will be documented in this file.
      This file is auto-generated by ChangelogManager. Any modifications made to it will be overwritten.


      \(unreleasedContentString)


      \(releaseContentString)
      """.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"

    try Folder.current.createFileIfNeeded(at: file.path).write(changelogString)
  }

  private func sectionString(
    name: String,
    entries: [ChangelogEntry],
    file: ChangelogManagerConfig.ChangelogFile
  ) -> String {
    let validEntries = entries.filter { !Set(file.tags).intersection($0.tags).isEmpty }
    let usedTags = validEntries.flatMap(\.tags).uniqueValues().sorted {
      if let index1 = file.tags.firstIndex(of: $0),
        let index2 = file.tags.firstIndex(of: $1)
      {
        return index1 < index2
      }
      else {
        return false
      }
    }

    let tagsString: String = usedTags.map { usedTag in
      let entriesString =
        validEntries
        .filter { $0.tags.contains(usedTag) }
        .map {
          "- \($0.description)"
        }.joined(separator: "\n")

      return """
        ### \(usedTag)
        \(entriesString)
        """
    }.joined(separator: "\n\n")

    return """
      ## [\(name)]
      \(tagsString)
      """
  }
}
