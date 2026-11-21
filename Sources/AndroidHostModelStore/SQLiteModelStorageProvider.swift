import CoreModel
import DynamicCoreModel
import RuntimeCoreModel
import SQLite
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Android)
import Android
#elseif canImport(Glibc)
import Glibc
#endif

/// Where the model store's stores are on Android (`Plan.md` §6.7): a
/// CoreModel-SQLite database each, `<name>.sqlite` in the app's databases
/// directory, which is `getDatabasePath`'s.
///
/// Each database keeps the model it was made with, as JSON in a table of
/// its own, `modelTable`. Opening a store with another model migrates it
/// by the contract's rules: when only entities and properties were added
/// or removed, the objects are copied into a new database of the new
/// model, which then replaces the old one. A new database is always made
/// beside the old one and renamed over it, so a store is never half made.
///
/// A store opened twice with the same model is one `SQLiteModelStorage`.
/// Opened with another model, or destroyed, the one before is closed.
public actor SQLiteModelStorageProvider: ModelStorageProvider {

    /// The table a database keeps its model in. No entity can have its
    /// name.
    public static let modelTable = "_appruntime_model"

    public let directory: String

    /// The open stores, with the model each was opened for, canonical.
    private var stores: [String: (model: Model, storage: SQLiteModelStorage)] = [:]

    public init(directory: String) {
        self.directory = directory
    }

    /// Where the store `name` is.
    public nonisolated func path(_ name: String) -> String {
        directory + "/" + name + ".sqlite"
    }

    public func open(_ name: String, model: Model, indexes: [EntityName: [[PropertyKey]]], migration: ModelMigration) async throws -> any ModelStorage {
        guard model[EntityName(rawValue: Self.modelTable)] == nil else {
            throw ModelStoreError(.invalidModel, message: "no entity can be named \(Self.modelTable): the store keeps its model there")
        }
        let canonical = Self.canonical(model)
        if let open = stores[name], open.model == canonical {
            return open.storage
        }
        try makeDirectory()
        let path = path(name)
        if Self.exists(path) {
            let stored = try Self.storedModel(at: path)
            if stored != canonical {
                if InMemoryModelStorageProvider.canMigrate(from: stored, to: model) {
                    await close(name)
                    try await migrate(path, from: stored, to: model)
                } else if migration == .fail {
                    throw ModelStoreError(.migrationRequired, message: "the store \(name) was made with another model")
                } else {
                    await close(name)
                    try await create(path, model: model)
                }
            }
        } else {
            try await create(path, model: model)
        }
        let storage = try SQLiteModelStorage(path: path, model: model)
        try await storage.makeIndexes(indexes, model: model)
        if let previous = stores[name] {
            await previous.storage.close()
        }
        stores[name] = (canonical, storage)
        return storage
    }

    public func destroy(_ name: String) async throws {
        await close(name)
        let path = path(name)
        for file in Self.files(of: path) + Self.files(of: path + ".new") {
            guard unlink(file) == 0 || errno == ENOENT else {
                throw ModelStoreError(.unavailable, message: "\(file) can't be removed: errno \(errno)")
            }
        }
    }

    // MARK: Files

    private func close(_ name: String) async {
        if let open = stores.removeValue(forKey: name) {
            await open.storage.close()
        }
    }

    private func makeDirectory() throws {
        var made = ""
        for component in directory.split(separator: "/") {
            made += "/" + component
            if mkdir(made, 0o700) != 0, errno != EEXIST {
                throw ModelStoreError(.unavailable, message: "\(made) can't be made: errno \(errno)")
            }
        }
    }

    /// Makes an empty store of `model` at `path`, replacing what's there.
    private func create(_ path: String, model: Model) async throws {
        try await replace(path, model: model) { _ in }
    }

    /// Copies what `stored`'s objects have that `model` has too into a new
    /// store of `model`, which replaces the one at `path`.
    private func migrate(_ path: String, from stored: Model, to model: Model) async throws {
        let old = try SQLiteModelStorage(path: path, model: stored)
        var objects: [ModelData] = []
        for entity in model.entities where stored[entity.id] != nil {
            for var object in try await old.fetch(FetchRequest(entity: entity.id)) {
                object.attributes = object.attributes.filter { entity[attribute: $0.key] != nil }
                object.relationships = object.relationships.filter { entity[relationship: $0.key] != nil }
                objects.append(object)
            }
        }
        await old.close()
        try await replace(path, model: model) { storage in
            try await storage.insert(objects)
        }
    }

    /// Makes a store of `model` beside `path`, fills it, and renames it
    /// over `path`.
    private func replace(_ path: String, model: Model, fill: (SQLiteModelStorage) async throws -> Void) async throws {
        let new = path + ".new"
        Self.remove(Self.files(of: new))
        do {
            let storage = try SQLiteModelStorage(path: new, model: model)
            try await fill(storage)
            try await storage.keep(Self.encoded(model))
            await storage.close()
        } catch {
            Self.remove(Self.files(of: new))
            throw ModelStoreError(error)
        }
        // The old database's journals would be taken for the new one's.
        Self.remove(Self.files(of: path).dropFirst())
        guard rename(new, path) == 0 else {
            let failure = errno
            Self.remove(Self.files(of: new))
            throw ModelStoreError(failure == ENOSPC ? .outOfSpace : .unavailable, message: "\(path) can't be replaced: errno \(failure)")
        }
    }

    private static func remove(_ files: some Sequence<String>) {
        for file in files {
            unlink(file)
        }
    }

    /// The files SQLite keeps for the database at `path`.
    static func files(of path: String) -> [String] {
        [path, path + "-journal", path + "-wal", path + "-shm"]
    }

    static func exists(_ path: String) -> Bool {
        access(path, F_OK) == 0
    }

    // MARK: The stored model

    /// The model the database at `path` was made with, canonical.
    static func storedModel(at path: String) throws -> Model {
        let text: String
        do {
            let connection = try Connection(path: path, isReadOnly: true)
            guard let value = try connection.scalar("SELECT model FROM \(quoted(modelTable))")?.string else {
                throw ModelStoreError(.corrupted, message: "\(path) has no model")
            }
            text = value
        } catch let error as SQLiteError where error.message.hasPrefix("no such table") {
            throw ModelStoreError(.corrupted, message: "\(path) isn't a model store")
        } catch {
            throw ModelStoreError(error)
        }
        do {
            return canonical(try JSONDecoder().decode(Model.self, from: Data(text.utf8)))
        } catch {
            throw ModelStoreError(.corrupted, message: "\(path)'s model doesn't read: \(error)")
        }
    }

    /// `model` as the JSON a database keeps.
    static func encoded(_ model: Model) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(canonical(model)), as: UTF8.self)
    }

    /// A model with its entities and properties in one order, so two that
    /// say the same thing are equal.
    static func canonical(_ model: Model) -> Model {
        Model(entities: model.entities
            .map { entity in
                EntityDescription(
                    id: entity.id,
                    attributes: entity.attributes.sorted { $0.id.rawValue < $1.id.rawValue },
                    relationships: entity.relationships.sorted { $0.id.rawValue < $1.id.rawValue }
                )
            }
            .sorted { $0.id.rawValue < $1.id.rawValue })
    }

    /// An SQL identifier.
    static func quoted(_ identifier: String) -> String {
        "\"" + identifier.replacing("\"", with: "\"\"") + "\""
    }
}
