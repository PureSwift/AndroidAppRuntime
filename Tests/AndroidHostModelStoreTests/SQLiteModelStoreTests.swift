import CoreModel
import DynamicCoreModel
import DynamicRuntime
import Foundation
import RuntimeCoreModel
import RuntimeNative
import SQLite
import Testing
@testable import AndroidHostModelStore

// MARK: The model

/// The model of AppRuntime's model store tests: a person of every
/// attribute type, on a team.
enum Fixture {

    static let model = Model(entities: [
        EntityDescription(id: "Person", attributes: [
            Attribute(id: "name", type: .string), Attribute(id: "age", type: .int32), Attribute(id: "rank", type: .int16),
            Attribute(id: "visits", type: .int64), Attribute(id: "ratio", type: .float), Attribute(id: "score", type: .double),
            Attribute(id: "isMember", type: .bool), Attribute(id: "joined", type: .date), Attribute(id: "token", type: .uuid),
            Attribute(id: "homepage", type: .url), Attribute(id: "balance", type: .decimal), Attribute(id: "photo", type: .data),
        ], relationships: [
            Relationship(id: "team", type: .toOne, destinationEntity: "Team", inverseRelationship: "members"),
        ]),
        EntityDescription(id: "Team", attributes: [Attribute(id: "name", type: .string)], relationships: [
            Relationship(id: "members", type: .toMany, destinationEntity: "Person", inverseRelationship: "team"),
        ]),
        EntityDescription(id: "Note", attributes: [Attribute(id: "text", type: .string)], relationships: []),
    ])

    static func person(_ id: String, _ name: String, age: Int32, score: Double = 0, isMember: Bool = false, team: String? = nil) -> ModelData {
        var data = ModelData(entity: "Person", id: ObjectID(rawValue: id))
        data.attributes = [
            "name": .string(name), "age": .int32(age), "rank": .int16(0), "visits": .int64(0), "ratio": .float(0),
            "score": .double(score), "isMember": .bool(isMember), "joined": .null, "token": .null, "homepage": .null,
            "balance": .null, "photo": .null,
        ]
        data.relationships["team"] = team.map { .toOne(ObjectID(rawValue: $0)) } ?? .null
        return data
    }

    static func team(_ id: String, _ name: String) -> ModelData {
        var data = ModelData(entity: "Team", id: ObjectID(rawValue: id))
        data.attributes["name"] = .string(name)
        return data
    }

    static let ada: ModelData = {
        var ada = person("ada", "Ada", age: 36, score: 9.5, isMember: true, team: "engine")
        ada.attributes["rank"] = .int16(-3)
        ada.attributes["visits"] = .int64(1 << 40)
        ada.attributes["ratio"] = .float(0.25)
        ada.attributes["joined"] = .date(Date(timeIntervalSince1970: 1_700_000_000.5))
        ada.attributes["token"] = .uuid(UUID(uuidString: "9E3C1A52-0C1B-4F0E-9D4B-6A1F2C3D4E5F")!)
        ada.attributes["homepage"] = .url(URL(string: "https://example.com/ada?x=1")!)
        ada.attributes["balance"] = .decimal(Decimal(string: "1234.5678")!)
        ada.attributes["photo"] = .data(Data([0, 1, 2, 255]))
        return ada
    }()

    static let objects: [ModelData] = [
        team("engine", "Engine"),
        team("theory", "Theory"),
        ada,
        person("grace", "Grace", age: 45, score: 8, isMember: true, team: "engine"),
        person("alan", "alan", age: 41, score: 7.25, team: "theory"),
        person("edsger", "Édsger", age: 17, score: 0),
        person("linus", "Linus", age: 17, score: 3, isMember: true, team: "theory"),
    ]

    /// Requests of every shape AppRuntime's tests ask, but those with a
    /// custom function, which the guest evaluates.
    static let predicates: [FetchRequest.Predicate?] = {
        typealias Predicate = FetchRequest.Predicate
        func compare(_ key: PropertyKey, _ value: AttributeValue, _ type: Predicate.Comparison.Operator, _ options: Set<Predicate.Comparison.Option> = []) -> Predicate {
            .comparison(.init(left: .keyPath(PredicateKeyPath(rawValue: key.rawValue)), right: .attribute(value), type: type, options: options))
        }
        let age: Predicate.Expression = .keyPath("age")
        return [
            nil,
            .value(true),
            .value(false),
            compare("age", .int32(18), .greaterThanOrEqualTo),
            compare("age", .int32(18), .lessThan),
            compare("age", .int32(17), .equalTo),
            compare("age", .int32(17), .notEqualTo),
            compare("score", .double(7.5), .greaterThan),
            compare("isMember", .bool(true), .equalTo),
            compare("name", .string("alan"), .equalTo),
            compare("name", .string("a"), .beginsWith),
            compare("name", .string("a"), .beginsWith, [.caseInsensitive]),
            compare("name", .string("N"), .endsWith, [.caseInsensitive]),
            compare("name", .string("ra"), .contains),
            compare("name", .string("*a*"), .like),
            compare("name", .string("Ada Lovelace"), .in),
            compare("joined", .null, .equalTo),
            compare("joined", .null, .notEqualTo),
            compare("joined", .date(Date(timeIntervalSince1970: 1_700_000_000.5)), .notEqualTo),
            compare("photo", .data(Data([0, 1, 2, 255])), .notEqualTo),
            compare("isMember", .bool(false), .lessThan),
            compare("name", .string("Grace"), .lessThan),
            .comparison(.init(left: .keyPath("team"), right: .relationship(.toOne("engine")), type: .notEqualTo)),
            compare("joined", .date(Date(timeIntervalSince1970: 1_600_000_000)), .greaterThan),
            compare("token", .uuid(UUID(uuidString: "9E3C1A52-0C1B-4F0E-9D4B-6A1F2C3D4E5F")!), .equalTo),
            compare("photo", .data(Data([0, 1, 2, 255])), .equalTo),
            compare("visits", .int64(1 << 40), .equalTo),
            .comparison(.init(left: .keyPath("team"), right: .relationship(.toOne("engine")), type: .equalTo)),
            .comparison(.init(left: .keyPath("team"), right: .relationship(.null), type: .equalTo)),
            .comparison(.init(left: .keyPath("team.name"), right: .attribute(.string("Theory")), type: .equalTo)),
            .comparison(.init(left: .arithmetic(.init(function: .add, left: age, right: .attribute(.int32(4)))), right: .attribute(.int32(45)), type: .equalTo)),
            .comparison(.init(left: .arithmetic(.init(function: .multiply, left: .keyPath("score"), right: .attribute(.double(2)))), right: .attribute(.double(15)), type: .greaterThan)),
            .compound(.and([compare("age", .int32(18), .greaterThanOrEqualTo), compare("isMember", .bool(true), .equalTo)])),
            .compound(.or([compare("age", .int32(18), .lessThan), compare("name", .string("Ada"), .equalTo)])),
            .compound(.not(compare("isMember", .bool(true), .equalTo))),
            .compound(.and([])),
            .compound(.or([])),
        ]
    }()

    static let sorts: [[FetchRequest.SortDescriptor]] = [
        [],
        [.init(property: "name")],
        [.init(property: "age"), .init(property: "score", ascending: false)],
        [.init(property: "joined", ascending: false)],
    ]
}

/// A directory of its own, removed at the end.
final class Directory {

    let path = NSTemporaryDirectory() + "AndroidHostModelStoreTests-" + UUID().uuidString + "/databases"

    deinit {
        try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    }
}

/// What a failing call failed with; `nil` when it didn't.
func failure(_ body: () async throws -> Void) async -> ModelStoreError.Code? {
    do {
        try await body()
        return nil
    } catch {
        return (error as? ModelStoreError)?.code
    }
}

// MARK: The provider

@Suite struct SQLiteModelStorageProviderTests {

    let directory = Directory()

    var provider: SQLiteModelStorageProvider {
        SQLiteModelStorageProvider(directory: directory.path)
    }

    func open(_ provider: SQLiteModelStorageProvider, _ model: Model = Fixture.model, migration: ModelMigration = .fail) async throws -> any ModelStorage {
        try await provider.open("library", model: model, indexes: [:], migration: migration)
    }

    func filled(_ provider: SQLiteModelStorageProvider) async throws -> any ModelStorage {
        let store = try await open(provider)
        try await store.insert(Fixture.objects)
        return store
    }

    @Test func valuesComeBackAsTheyWent() async throws {
        let store = try await filled(provider)
        let ada = try #require(try await store.fetch("Person", for: "ada"))
        #expect(ada.attributes == Fixture.ada.attributes)
        #expect(ada.relationships["team"] == .toOne("engine"))

        let grace = try #require(try await store.fetch("Person", for: "grace"))
        #expect(grace.attributes["joined"] == .null, "a null isn't a zero")
        #expect(grace.attributes["rank"] == .int16(0), "a zero isn't a null")
        let engine = try #require(try await store.fetch("Team", for: "engine"))
        #expect(engine.relationships["members"].map { relationship -> [ObjectID] in
            if case .toMany(let ids) = relationship { return ids.sorted { $0.rawValue < $1.rawValue } }
            return []
        } == ["ada", "grace"], "the other side of a relationship is kept")
        #expect(try await store.fetch("Person", for: "nobody") == nil)
    }

    /// Every request answered by SQLite as CoreModel's own in-memory
    /// storage answers it: the reference for what a request returns.
    @Test func requestsMatchCoreModelsOwnAnswers() async throws {
        let store = try await filled(provider)
        let reference = InMemoryModelStorage(model: Fixture.model)
        try await reference.insert(Fixture.objects)

        var compared = 0
        for predicate in Fixture.predicates {
            for sort in Fixture.sorts {
                for (limit, offset) in [(0, 0), (2, 0), (2, 1), (0, 4)] {
                    let request = FetchRequest(entity: "Person", sortDescriptors: sort, predicate: predicate, fetchLimit: limit, fetchOffset: offset)
                    let expected = try await reference.fetch(request).map(\.id)
                    #expect(try await store.fetch(request).map(\.id) == expected, "\(String(describing: predicate)) \(sort) \(limit) \(offset)")
                    #expect(try await store.fetchID(request) == expected, "\(String(describing: predicate)) \(sort) \(limit) \(offset)")
                    #expect(try await store.count(request) == UInt(expected.count), "\(String(describing: predicate)) \(sort) \(limit) \(offset)")
                    compared += 1
                }
            }
        }
        #expect(compared == Fixture.predicates.count * 16)

        let members: FetchRequest.Predicate = .comparison(.init(left: .keyPath("members"), right: .relationship(.toOne("linus")), type: .contains))
        #expect(try await store.fetchID(FetchRequest(entity: "Team", predicate: members)) == ["theory"])
        let anyMember: FetchRequest.Predicate = .comparison(.init(left: .keyPath("members.age"), right: .attribute(.int32(40)), type: .greaterThan, modifier: .any))
        #expect(try await store.fetchID(FetchRequest(entity: "Team", predicate: anyMember)) == (try await reference.fetchID(FetchRequest(entity: "Team", predicate: anyMember))))
    }

    /// What SQLite is given, and what's left to CoreModel.
    @Test func sqliteIsGivenWhatItAnswersTheSame() throws {
        let person = try #require(Fixture.model[EntityName(rawValue: "Person")])
        func pushdown(_ predicate: FetchRequest.Predicate?, sort: [FetchRequest.SortDescriptor] = []) -> Pushdown {
            Pushdown(FetchRequest(entity: "Person", sortDescriptors: sort, predicate: predicate), entity: person)
        }
        let adult: FetchRequest.Predicate = .comparison(.init(left: .keyPath("age"), right: .attribute(.int32(18)), type: .greaterThanOrEqualTo))
        let begins: FetchRequest.Predicate = .comparison(.init(left: .keyPath("name"), right: .attribute(.string("a")), type: .beginsWith))
        let onTeam: FetchRequest.Predicate = .comparison(.init(left: .keyPath("team.name"), right: .attribute(.string("Theory")), type: .equalTo))

        #expect(pushdown(nil).answersWhole(FetchRequest(entity: "Person")))
        #expect(pushdown(adult).isExact)
        #expect(pushdown(.compound(.or([adult, adult]))).isExact)
        #expect(!pushdown(adult, sort: [.init(property: "name")]).answersWhole(FetchRequest(entity: "Person", sortDescriptors: [.init(property: "name")], predicate: adult)), "CoreModel sorts")
        #expect(pushdown(adult, sort: [.init(property: "name")]).predicate == adult, "but SQLite still filters")

        let both = pushdown(.compound(.and([adult, begins])))
        #expect(!both.isExact)
        #expect(both.predicate == .compound(.and([adult])), "an AND gives SQLite what it can say")
        #expect(pushdown(.compound(.or([adult, begins]))).predicate == nil, "an OR can't be narrowed")
        #expect(pushdown(begins).predicate == nil)
        #expect(!pushdown(onTeam).isExact)
        #expect(pushdown(onTeam).needsRelated)
        #expect(!pushdown(begins).needsRelated)
        #expect(pushdown(.compound(.or([]))).predicate == .value(false))
        #expect(pushdown(.compound(.and([]))).predicate == .value(true))
    }

    @Test func aBatchIsAppliedInOrderAndMerges() async throws {
        let store = try #require(try await filled(provider) as? SQLiteModelStorage)
        var partial = ModelData(entity: "Person", id: "ada")
        partial.attributes["age"] = .int32(37)
        partial.attributes["photo"] = .null
        var changes = ModelChanges()
        changes.insert(partial)
        changes.insert(Fixture.person("new", "New", age: 1))
        changes.delete("Person", for: "new")
        changes.delete("Person", for: "linus")
        changes.delete("Person", for: "never-there")
        try await store.perform(changes)

        let ada = try #require(try await store.fetch("Person", for: "ada"))
        #expect(ada.attributes["age"] == .int32(37))
        #expect(ada.attributes["name"] == .string("Ada"), "left as it was")
        #expect(ada.attributes["photo"] == .null, "set to null")
        #expect(try await store.fetchID(FetchRequest(entity: "Person")) == ["ada", "alan", "edsger", "grace"])
        try await store.perform(ModelChanges())
    }

    /// A batch that fails in the database, after the adapter has checked
    /// it, changes nothing: what it did before the failure is rolled back.
    @Test func aBatchThatFailsChangesNothing() async throws {
        let provider = provider
        let store = try #require(try await filled(provider) as? SQLiteModelStorage)
        // A failure only the database knows of: a trigger refuses one ID.
        let database = try Connection(path: provider.path("library"))
        try database.run("CREATE TRIGGER refuse BEFORE INSERT ON \"Person\" WHEN NEW.id = 'refused' BEGIN SELECT RAISE(ABORT, 'refused'); END")

        var changes = ModelChanges()
        changes.insert(Fixture.person("good", "Good", age: 1))
        changes.delete("Person", for: "ada")
        changes.insert(Fixture.team("new", "New"))
        changes.insert(Fixture.person("refused", "Refused", age: 1))
        #expect(await failure { try await store.perform(changes) } != nil)

        #expect(try await store.fetchID(FetchRequest(entity: "Person")) == ["ada", "alan", "edsger", "grace", "linus"])
        #expect(try await store.count(FetchRequest(entity: "Team")) == 2)
        #expect(try await store.fetch("Person", for: "ada")?.relationships["team"] == .toOne("engine"))

        // And the next batch is applied: the transaction ended.
        var next = ModelChanges()
        next.insert(Fixture.person("good", "Good", age: 1))
        try await store.perform(next)
        #expect(try await store.count(FetchRequest(entity: "Person")) == 6)
    }

    @Test func aStoreKeepsItsObjectsBetweenOpenings() async throws {
        _ = try await filled(provider)
        // Another provider, as at the app's next launch.
        let again = try await open(provider)
        #expect(try await again.count(FetchRequest(entity: "Person")) == 5)

        let provider = provider
        try await provider.destroy("library")
        #expect(!FileManager.default.fileExists(atPath: provider.path("library")))
        try await provider.destroy("library")
        let fresh = try await open(provider)
        #expect(try await fresh.count(FetchRequest(entity: "Person")) == 0)
    }

    @Test func aStoreOpenedTwiceIsOneStorage() async throws {
        let provider = provider
        let first = try await open(provider)
        // The same model, said in another order.
        let reordered = Model(entities: Fixture.model.entities.reversed().map {
            EntityDescription(id: $0.id, attributes: $0.attributes.reversed(), relationships: $0.relationships)
        })
        let second = try await open(provider, reordered)
        #expect(first === second)
    }

    @Test func theDatabaseKeepsItsModel() async throws {
        let provider = provider
        _ = try await open(provider)
        let stored = try SQLiteModelStorageProvider.storedModel(at: provider.path("library"))
        #expect(stored == SQLiteModelStorageProvider.canonical(Fixture.model))
        #expect(stored != Fixture.model, "the fixture isn't in canonical order, so the comparison means something")
    }

    @Test func aChangedModelMigratesOrIsRefused() async throws {
        let provider = provider
        let first = try await filled(provider)

        var grown = Fixture.model
        grown.entities[0].attributes.append(Attribute(id: "nickname", type: .string))
        grown.entities[0].attributes.removeAll { $0.id == "photo" }
        grown.entities.append(EntityDescription(id: "Tag", attributes: [Attribute(id: "text", type: .string)], relationships: []))
        grown.entities.removeAll { $0.id == "Note" }
        let store = try await open(provider, grown)
        let ada = try #require(try await store.fetch("Person", for: "ada"))
        #expect(ada.attributes["name"] == .string("Ada"))
        #expect(ada.attributes["balance"] == Fixture.ada.attributes["balance"])
        #expect(ada.attributes["nickname"] == .null, "what's new reads as null")
        #expect(ada.attributes["photo"] == nil)
        #expect(ada.relationships["team"] == .toOne("engine"))
        #expect(try await store.fetch("Team", for: "theory")?.relationships["members"] == .toMany(["alan", "linus"]))
        #expect(try await store.count(FetchRequest(entity: "Tag")) == 0)
        #expect(await failure { _ = try await first.count(FetchRequest(entity: "Person")) } == .unavailable, "the store before was closed")

        // A type that changed can't be read as the new one.
        var retyped = grown
        retyped.entities[0].attributes.removeAll { $0.id == "age" }
        retyped.entities[0].attributes.append(Attribute(id: "age", type: .string))
        #expect(await failure { _ = try await open(provider, retyped) } == .migrationRequired)
        #expect(try await store.count(FetchRequest(entity: "Person")) == 5, "the refusal changed nothing")
        #expect(try await open(SQLiteModelStorageProvider(directory: directory.path), grown).count(FetchRequest(entity: "Person")) == 5)

        let emptied = try await open(provider, retyped, migration: .reset)
        #expect(try await emptied.count(FetchRequest(entity: "Person")) == 0)
        #expect(try SQLiteModelStorageProvider.storedModel(at: provider.path("library")) == SQLiteModelStorageProvider.canonical(retyped))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".new") }
        #expect(leftovers.isEmpty)
    }

    @Test func whatIsNotAStoreIsCorrupted() async throws {
        let provider = provider
        _ = try await open(provider)
        try await provider.destroy("library")
        try Data("not a database, and long enough for SQLite to look at it: ".utf8 + Array(repeating: 7, count: 200)).write(to: URL(fileURLWithPath: provider.path("library")))
        #expect(await failure { _ = try await open(provider) } == .corrupted)

        // A database, but not one a store made.
        try await provider.destroy("library")
        let other = try Connection(path: provider.path("library"))
        try other.run("CREATE TABLE things (id TEXT)")
        #expect(await failure { _ = try await open(provider) } == .corrupted)
        try await provider.destroy("library")
        #expect(try await open(provider).count(FetchRequest(entity: "Person")) == 0)
    }

    @Test func noEntityCanTakeTheModelsTable() async throws {
        let model = Model(entities: [EntityDescription(id: EntityName(rawValue: SQLiteModelStorageProvider.modelTable), attributes: [], relationships: [])])
        #expect(await failure { _ = try await open(provider, model) } == .invalidModel)
    }

    @Test func indexesAreMadeOnColumns() async throws {
        let provider = provider
        _ = try await provider.open("library", model: Fixture.model, indexes: [
            "Person": [["name"], ["age", "team"], ["name", "missing"]],
            "Team": [["members"]],
        ], migration: .fail)
        let database = try Connection(path: provider.path("library"), isReadOnly: true)
        let statement = try database.prepare("SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'appruntime%' ORDER BY name")
        var names: [String] = []
        while let row = try statement.failableNext() {
            names.append(row[0]?.string ?? "")
        }
        #expect(names == ["appruntime_Person_age_team", "appruntime_Person_name"])
    }

    @Test func sqliteErrorsAreTheContracts() throws {
        let database = try Connection(path: ":memory:")
        do {
            try database.run("SELECT * FROM nothing")
            Issue.record("expected an error")
        } catch {
            #expect(ModelStoreError(error).code == .unknown)
            #expect(ModelStoreError(error).message.contains("nothing"))
        }
        #expect(ModelStoreError(ModelStoreError(.outOfSpace)).code == .outOfSpace)
    }
}

// MARK: Through the contracts

/// A guest's `RuntimeModelStorage`, through `NativeRuntime` and
/// `HostModelStore`, to a store on disk.
///
/// Serialized, and on the main actor: `HostModelStore`'s configuration is
/// shared, and the guest's calls and the host's answers must share a
/// thread, as they do in a host.
@MainActor @Suite(.serialized) final class SQLiteModelStoreContractTests {

    let directory = Directory()

    init() {
        let native = NativeRuntime.shared
        // This package's AppRuntime has no guest exports: the host's own
        // Swift reaches the runtime directly, as on Android.
        native.bindDirectly()
        native.capabilities = nil
        HostModelStore.configure(.init(provider: SQLiteModelStorageProvider(directory: directory.path)))
        AndroidHostModelStore.register(in: native)
    }

    @Test func aGuestKeepsItsObjectsOnDisk() async throws {
        do {
            let store = try await RuntimeModelStorage.open("library", model: Fixture.model)
            var changes = ModelChanges()
            for object in Fixture.objects {
                changes.insert(object)
            }
            try await store.perform(changes)
            #expect(try await store.fetch("Person", for: "ada")?.attributes == Fixture.ada.attributes)
            let adults = FetchRequest(entity: "Person", sortDescriptors: [.init(property: "name")], predicate: .comparison(.init(left: .keyPath("age"), right: .attribute(.int32(18)), type: .greaterThanOrEqualTo)))
            #expect(try await store.fetchID(adults) == ["Ada", "Grace", "alan"].map { name in
                ObjectID(rawValue: Fixture.objects.first { $0.attributes["name"] == .string(name) }!.id.rawValue)
            })
        }
        // A new provider, as at the next launch.
        HostModelStore.configure(.init(provider: SQLiteModelStorageProvider(directory: directory.path)))
        let again = try await RuntimeModelStorage.open("library", model: Fixture.model)
        #expect(try await again.count(FetchRequest(entity: "Person")) == 5)

        try await RuntimeModelStorage.destroy("library")
        #expect(!FileManager.default.fileExists(atPath: directory.path + "/library.sqlite"))
    }
}
