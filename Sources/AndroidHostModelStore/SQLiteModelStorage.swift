import CoreModel
import CoreModelSQLite
import DynamicCoreModel
import RuntimeCoreModel
import SQLite

/// One store: a CoreModel-SQLite database, with batches applied in one
/// transaction, and SQLite's errors as the contract's.
///
/// The provider closes it when the store is opened again with another
/// model, or destroyed: its file is replaced or gone, so from then on it
/// fails everything with `unavailable`.
public actor SQLiteModelStorage: AtomicModelStorage {

    private var database: SQLiteDatabase?

    let path: String

    let model: Model

    init(path: String, model: Model) throws {
        self.path = path
        self.model = model
        do {
            database = try SQLiteDatabase(path: path, model: model)
        } catch {
            throw ModelStoreError(error)
        }
    }

    /// Lets the database go; it's closed with the last of its work.
    func close() {
        database = nil
    }

    /// Runs `body` on the open database, with what it throws as the
    /// contract's errors.
    private func run<T: Sendable>(_ body: (SQLiteDatabase) async throws -> T) async throws -> T {
        guard let database else {
            throw ModelStoreError(.unavailable, message: "the store was opened again with another model, or destroyed")
        }
        do {
            return try await body(database)
        } catch {
            throw ModelStoreError(error)
        }
    }

    public func fetch(_ entity: EntityName, for id: ObjectID) async throws -> ModelData? {
        try await run { try await $0.fetch(entity, for: id) }
    }

    /// SQLite answers what it answers as CoreModel does (`Pushdown`), and
    /// CoreModel's own evaluator the rest, over what SQLite narrowed it to.
    public func fetch(_ fetchRequest: FetchRequest) async throws -> [ModelData] {
        let pushdown = try pushdown(for: fetchRequest)
        if pushdown.answersWhole(fetchRequest) {
            let whole = pushdown.whole(fetchRequest)
            return try await run { try await $0.fetch(whole) }
        }
        return try await evaluate(fetchRequest, pushdown)
    }

    public func fetchID(_ fetchRequest: FetchRequest) async throws -> [ObjectID] {
        let pushdown = try pushdown(for: fetchRequest)
        if pushdown.answersWhole(fetchRequest) {
            let whole = pushdown.whole(fetchRequest)
            return try await run { try await $0.fetchID(whole) }
        }
        return try await evaluate(fetchRequest, pushdown).map(\.id)
    }

    /// Counted without the limit and offset, which are applied to the
    /// count after: CoreModel-SQLite 0.3.3 puts them on `SELECT COUNT(*)`,
    /// whose one row an offset skips. A sort doesn't change a count.
    public func count(_ fetchRequest: FetchRequest) async throws -> UInt {
        var all = fetchRequest
        all.fetchLimit = 0
        all.fetchOffset = 0
        all.sortDescriptors = []
        let pushdown = try pushdown(for: all)
        let total: UInt
        if pushdown.answersWhole(all) {
            let whole = pushdown.whole(all)
            total = try await run { try await $0.count(whole) }
        } else {
            total = UInt(try await evaluate(all, pushdown).count)
        }
        let offset = UInt(max(fetchRequest.fetchOffset, 0))
        let left = total > offset ? total - offset : 0
        return fetchRequest.fetchLimit > 0 ? min(left, UInt(fetchRequest.fetchLimit)) : left
    }

    private func pushdown(for request: FetchRequest) throws -> Pushdown {
        guard let entity = model[request.entity] else {
            throw ModelStoreError(.invalidRequest, message: "the model has no entity \(request.entity)")
        }
        return Pushdown(request, entity: entity)
    }

    /// Fetches what SQLite can narrow the request to, and the objects a
    /// key path may reach, and has CoreModel evaluate the request on them.
    private func evaluate(_ request: FetchRequest, _ pushdown: Pushdown) async throws -> [ModelData] {
        let narrowed = FetchRequest(entity: request.entity, predicate: pushdown.predicate)
        var objects = try await run { try await $0.fetch(narrowed) }
        if pushdown.needsRelated {
            for entity in model.entities where entity.id != request.entity {
                objects += try await run { try await $0.fetch(FetchRequest(entity: entity.id)) }
            }
        }
        var rest = request
        if pushdown.isExact {
            rest.predicate = nil
        }
        return rest.evaluate(objects)
    }

    public func insert(_ value: ModelData) async throws {
        try await run { try await $0.insert(value) }
    }

    public func insert(_ values: [ModelData]) async throws {
        try await run { try await $0.insert(values) }
    }

    public func delete(_ entity: EntityName, for id: ObjectID) async throws {
        try await run { try await $0.delete(entity, for: id) }
    }

    public func delete(_ entity: EntityName, for ids: [ObjectID]) async throws {
        try await run { try await $0.delete(entity, for: ids) }
    }

    public func register(function: DatabaseFunction) async throws {
        try await run { try await $0.register(function: function) }
    }

    /// Applies the changes in one transaction: all of them, or none.
    ///
    /// Each insert and delete runs in a transaction of its own, which
    /// SQLite nests in this one as a savepoint. `HostModelStore` runs one
    /// operation at a time for a store, so nothing else reaches the
    /// database between `BEGIN` and `COMMIT`.
    public func perform(_ changes: ModelChanges) async throws {
        try await run { database in
            try await database.execute("BEGIN IMMEDIATE")
            do {
                for change in changes.changes {
                    switch change {
                    case .insert(let data):
                        try await database.insert(data)
                    case .delete(let entity, let id):
                        try await database.delete(entity, for: id)
                    }
                }
                try await database.execute("COMMIT")
            } catch {
                try? await database.execute("ROLLBACK")
                throw error
            }
        }
    }

    /// Keeps the model, as `SQLiteModelStorageProvider.encoded` gives it.
    func keep(_ model: String) async throws {
        let table = SQLiteModelStorageProvider.quoted(SQLiteModelStorageProvider.modelTable)
        try await run { database in
            try await database.execute("CREATE TABLE \(table) (model TEXT NOT NULL)")
            try await database.execute("INSERT INTO \(table) (model) VALUES (?)", [.text(model)])
        }
    }

    /// Makes the indexes the guest declared, on the keys that are columns:
    /// attributes and to-one relationships. A to-many has no column, and
    /// an index on one is left out.
    func makeIndexes(_ indexes: [EntityName: [[PropertyKey]]], model: Model) async throws {
        for (entityName, keyLists) in indexes {
            guard let entity = model[entityName] else { continue }
            for keys in keyLists {
                let columns = keys.filter { key in
                    entity[attribute: key] != nil || entity[relationship: key]?.type == .toOne
                }
                guard !columns.isEmpty, columns.count == keys.count else { continue }
                let index = (["appruntime", entityName.rawValue] + columns.map(\.rawValue)).joined(separator: "_")
                let list = columns.map { SQLiteModelStorageProvider.quoted($0.rawValue) }.joined(separator: ", ")
                let sql = "CREATE INDEX IF NOT EXISTS \(SQLiteModelStorageProvider.quoted(index)) ON \(SQLiteModelStorageProvider.quoted(entityName.rawValue)) (\(list))"
                try await run { try await $0.execute(sql) }
            }
        }
    }
}

extension ModelStoreError {

    /// What a backend threw, as the contract says it.
    init(_ error: any Error) {
        switch error {
        case let error as ModelStoreError:
            self = error
        case let error as SQLiteError:
            self.init(sqlite: error)
        case let error as SQLiteDatabaseError:
            switch error {
            case .invalidBinding(_, let type):
                self.init(.corrupted, message: "a stored value doesn't read as \(type)")
            case .invalidProperty(let key, let entity):
                self.init(.invalidRequest, message: "\(entity) has no column \(key)")
            case .invalidPredicate:
                self.init(.unsupported, message: "a predicate SQLite can't evaluate")
            case .unableToCreateFunction(let name, let code):
                self.init(.unsupported, message: "the function \(name) can't be registered: SQLite error \(code)")
            }
        default:
            self.init(.unknown, message: "\(error)")
        }
    }

    /// SQLite's primary result codes that mean something to an app.
    init(sqlite error: SQLiteError) {
        let message = error.message
        switch error.errorCode.rawValue & 0xff {
        case 13: // SQLITE_FULL
            self.init(.outOfSpace, message: message)
        case 11, 26: // SQLITE_CORRUPT, SQLITE_NOTADB
            self.init(.corrupted, message: message)
        case 3, 8, 14, 23: // SQLITE_PERM, SQLITE_READONLY, SQLITE_CANTOPEN, SQLITE_AUTH
            self.init(.unavailable, message: message)
        default:
            self.init(.unknown, message: message)
        }
    }
}
