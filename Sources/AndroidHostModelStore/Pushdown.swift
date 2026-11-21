import CoreModel

/// How much of a request SQLite answers the way CoreModel's in-memory
/// evaluator does, which defines what a request returns (§7.9).
///
/// SQLite is given what it agrees on: comparisons of one of the entity's
/// own columns with a constant, by `==`, `<`, `<=`, `>` and `>=`, with no
/// options, and the compounds of those. CoreModel evaluates the rest,
/// on what SQLite has narrowed it to:
///
/// - sorts: CoreModel orders a null as equal to anything, and SQLite
///   puts nulls first;
/// - string operators, and options: SQLite's `LIKE` ignores case;
/// - `IN`, arithmetic, functions, modifiers, and key paths through a
///   relationship;
/// - `!=`: a null isn't unequal to anything in SQL.
struct Pushdown {

    /// What SQLite can filter by: everything the request matches, and
    /// maybe more. `nil` for every object of the entity.
    let predicate: FetchRequest.Predicate?

    /// Whether `predicate` is the request's whole predicate.
    let isExact: Bool

    /// Whether evaluating the predicate needs the objects of other
    /// entities, for a key path through a relationship.
    let needsRelated: Bool

    init(_ request: FetchRequest, entity: EntityDescription) {
        guard let predicate = request.predicate else {
            self.predicate = nil
            isExact = true
            needsRelated = false
            return
        }
        let split = Self.split(Self.normalized(predicate), entity)
        self.predicate = split.pushed
        isExact = split.isExact
        needsRelated = Self.traverses(predicate)
    }

    /// Whether SQLite answers the whole request, sort, limit and offset
    /// included.
    func answersWhole(_ request: FetchRequest) -> Bool {
        isExact && request.sortDescriptors.isEmpty
    }

    /// `predicate` with an empty `AND` as true and an empty `OR` as false,
    /// as CoreModel reads them. CoreModel-SQLite 0.3.3 makes both true.
    static func normalized(_ predicate: FetchRequest.Predicate) -> FetchRequest.Predicate {
        switch predicate {
        case .compound(.and(let conditions)):
            return conditions.isEmpty ? .value(true) : .compound(.and(conditions.map(normalized)))
        case .compound(.or(let conditions)):
            return conditions.isEmpty ? .value(false) : .compound(.or(conditions.map(normalized)))
        case .compound(.not(let condition)):
            return .compound(.not(normalized(condition)))
        case .comparison, .value:
            return predicate
        }
    }

    /// The request as SQLite is given it, when it answers the whole of it.
    func whole(_ request: FetchRequest) -> FetchRequest {
        var whole = request
        whole.predicate = predicate
        return whole
    }

    /// The part of `predicate` SQLite can filter by, and whether it's all
    /// of it. An `AND` gives up only its other conditions; anything else
    /// SQLite can't say exactly, it can't narrow either.
    static func split(_ predicate: FetchRequest.Predicate, _ entity: EntityDescription) -> (pushed: FetchRequest.Predicate?, isExact: Bool) {
        if isExact(predicate, entity) {
            return (predicate, true)
        }
        if case .compound(.and(let conditions)) = predicate {
            let pushed = conditions.filter { isExact($0, entity) }
            return (pushed.isEmpty ? nil : .compound(.and(pushed)), false)
        }
        return (nil, false)
    }

    static func isExact(_ predicate: FetchRequest.Predicate, _ entity: EntityDescription) -> Bool {
        switch predicate {
        case .value:
            return true
        case .compound(.and(let conditions)), .compound(.or(let conditions)):
            return conditions.allSatisfy { isExact($0, entity) }
        case .compound(.not(let condition)):
            return isExact(condition, entity)
        case .comparison(let comparison):
            return isExact(comparison, entity)
        }
    }

    static func isExact(_ comparison: FetchRequest.Predicate.Comparison, _ entity: EntityDescription) -> Bool {
        guard comparison.options.isEmpty, comparison.modifier == nil else {
            return false
        }
        guard case .keyPath(let path) = comparison.left, path.keys.count == 1 else {
            return false
        }
        let key = PropertyKey(rawValue: path.keys[0].rawValue)
        switch comparison.right {
        case .attribute(let value):
            guard entity[attribute: key] != nil else { return false }
            switch comparison.type {
            case .equalTo:
                return true
            case .lessThan, .lessThanOrEqualTo, .greaterThan, .greaterThanOrEqualTo:
                // A boolean and a blob aren't ordered the same in both.
                switch value {
                case .bool, .data: return false
                default: return true
                }
            default:
                return false
            }
        case .relationship(let value):
            guard entity[relationship: key]?.type == .toOne, comparison.type == .equalTo else { return false }
            switch value {
            case .null, .toOne: return true
            case .toMany: return false
            }
        default:
            return false
        }
    }

    /// Whether a key path in `predicate` goes through a relationship.
    static func traverses(_ predicate: FetchRequest.Predicate) -> Bool {
        switch predicate {
        case .value:
            return false
        case .compound(.and(let conditions)), .compound(.or(let conditions)):
            return conditions.contains(where: traverses)
        case .compound(.not(let condition)):
            return traverses(condition)
        case .comparison(let comparison):
            return traverses(comparison.left) || traverses(comparison.right)
        }
    }

    static func traverses(_ expression: FetchRequest.Predicate.Expression) -> Bool {
        switch expression {
        case .keyPath(let path):
            return path.keys.count > 1
        case .arithmetic(let arithmetic):
            return traverses(arithmetic.left) || traverses(arithmetic.right)
        case .function:
            // A function's arguments may be key paths too; the guest
            // evaluates requests with functions, so this host never sees one.
            return true
        default:
            return false
        }
    }
}
