//
//  File.swift
//  
//
//  Created by AFuture D. on 2022/5/17.
//

import Foundation
import FluentKit

public protocol Dragable: Model {
    static var itemInsertStep: Int { get }
    static var maxSortValue: Int { get }
    static var sortKey: KeyPath<Self, Field<Int>> { get }
}

extension SiblingsProperty {
    public func pivotByID(_ id: To.IDValue, on database: Database) async throws -> Through? {
        return try await self.$pivots.query(on: database)
            .filter(self.to.appending(path: \.$id) == id)
            .first()
    }
}

extension SiblingsProperty where Through: Dragable {
    
    enum SiblingSortError: Error, LocalizedError, CustomStringConvertible {
        case pivotNotFound(pivotID: To.IDValue)
        case noSortValueAvailable
        
        public var description: String {
            switch self {
            case let .pivotNotFound(pivotID):
                return "No pivot found when try to search the pivot: \(pivotID)"
            case .noSortValueAvailable:
                return "Generate sort value error when trying to resolve conflict."
            }
        }
        
        public var errorDescription: String? {
            return self.description
        }
    }
    
    public enum Position {
        case beginning
        case end
    }
    
    /// return ``[Model]`` sorted by ``sortKey``
    public func getSorted (
        on database: Database
    ) async throws -> Value {
        guard let fromID = self.fromId else {
            fatalError("Cannot query siblings relation \(self.name) from unsaved model.")
        }
        return try await To.query(on: database)
            .join(Through.self, on: \To._$id == self.to.appending(path: \.$id))
            .filter(Through.self, self.from.appending(path: \.$id) == fromID)
            .sort(Through.self, Through.sortKey)
            .all()
    }
    
    func attach(
        _ to: To,
        method: AttachMethod = .ifNotExists,
        on database: Database,
        _ edit: @escaping (Through) -> () = { _ in },
        pos: Position = .end
    ) async throws {
        // TODO: support pos
        let sv = try await self.initSortValue(on: database)
        try await self.attach(to, method: method, on: database, { obj in
            obj[keyPath: Through.sortKey].value = sv
            edit(obj)
        })
    }
    
    public func initSortValue(on database: Database) async throws -> Int {
        return try await self.nextSortValue(before: nil, after: nil, on: database)
    }
    
    /// Drag & Drop Sort Impliment
    ///
    /// This method will set ``sortKey`` with a proper value.
    ///
    /// Algorithm:
    ///   1. generate next sort value
    ///   5. check validation
    ///   6. resolve conflict if necessary and go to 1.
    ///   7. Done.
    public func move(_ id: To.IDValue, before: To.IDValue? = nil, after: To.IDValue? = nil, on database: Database) async throws {
        guard var pivot = try await self.pivotByID(id, on: database) else {
            throw SiblingSortError.pivotNotFound(pivotID: id)
        }
        
        var next = try await self.nextSortValue(before: before, after: after, on: database)
        
        pivot[keyPath: Through.sortKey].value = next
        
        try await pivot.save(on: database)
    }
    
    public func nextSortValue(before: To.IDValue?, after: To.IDValue?, on database: Database) async throws -> Int {
        // If before and after is nil, than this is a insert operation.
        var next = try await self.generateSortValue(before: before, after: after, on: database)
        
        // resolve conflict just need once
        if try await self.isSortValueVaild(next, on: database) != true {
            try await self.resolveConflict(on: database)
            next = try await self.generateSortValue(before: before, after: after, on: database)
        }
        
        guard try await self.isSortValueVaild(next, on: database) else {
            throw  SiblingSortError.noSortValueAvailable
        }
        return next
    }
    
    public func isSortValueVaild(_ sortValue: Int, on database: Database) async throws -> Bool {
        return try await self.isConflict(sortValue, on: database) != true && sortValue <= Through.maxSortValue
    }
    
    /// check if given sortValue has already exists.
    public func isConflict(_ sortValue: Int, on database: Database) async throws -> Bool {
        let res: Bool = try await self.$pivots.query(on: database)
            .filter(Through.sortKey == sortValue)
            .first() != nil
        return res
    }
    
    /// reset all sortValue
    public func resolveConflict(on database: Database) async throws {
        let objs = try await self.$pivots.get(reload: true, on: database)
        print("before conflict \(objs)")
        let objCnt = objs.count
        _ = try objs.enumerated().map { idx, obj -> Through in
            obj[keyPath: Through.sortKey].value = Through.maxSortValue / objCnt * idx
            return obj
        }.map {
            $0.update(on: database)
        }.flatten(on: database.eventLoop).wait()
        let objss = try await self.$pivots.get(reload: true, on: database)
        print("after conflict \(objss)")
    }
    
    /// generate next sortValue
    ///
    /// Algorithm:
    ///   1. sortValue = MAX / 2 When inset first.
    ///   2. sortvalue = sort value of last item + STEP
    ///   3. sortValue = ⎣sort value of first item / 2⎦ when move to the beginning
    ///   4. sortValue = ⎣(MAX - sort value of last item) / 2⎦ when move to the end
    ///   5. sortValue = ⎣(sort value of item before - sort value of item after) / 2⎦ when move to the middle
    ///
    /// Notice:
    ///   - MAX: the max value of UInt
    ///   - STEP: 2^32
    ///
    /// Detail:
    ///   The maximum number of element in list is 2^64 - 1.
    ///   So, We try to decompose the list into 2^32 parts and each part has 2^32 element.
    ///
    ///   When trying to add a new element, the sort value of this element is just add 2^32 to
    ///   the sort value of last one. so that, we have 2^32 times operations without any other calculation.
    ///
    ///   When trying to move an element there will be 32 times operations without any other calculation.
    ///   Only when the conflict happend, the resolve operation would be needed, which the possibility would be 1/2^32.
    public func generateSortValue(before: To.IDValue?, after: To.IDValue?, on database: Database) async throws -> Int {
        let beforeIdx = try await self.sortValue(before, on: database)
        let afterIdx = try await self.sortValue(after, on: database)
        
        var resIdx: Int
        
        if beforeIdx == nil && afterIdx == nil {
            // Inset new element.
            if let maxSortValue = try await self.maxSortValue(on: database) {
                resIdx = maxSortValue + Through.itemInsertStep
            } else {
                // the first element
                resIdx = Through.maxSortValue / 2
            }
        } else if beforeIdx == nil && afterIdx != nil {
            // begin of list
            resIdx = afterIdx! / 2
        } else if beforeIdx != nil && afterIdx == nil {
            // end of list
            resIdx = Through.maxSortValue / 2 + beforeIdx! / 2
        } else {
            // middle of list
            resIdx = beforeIdx!/2 + afterIdx!/2
        }
        
        return resIdx
    }
    
    /// get sortValue by ID
    public func sortValue(_ id: To.IDValue?, on database: Database) async throws -> Int? {
        // check id
        guard let aID = id else {
            return nil
        }
        
        // get obj bt id
        guard let obj = try await self.pivotByID(aID, on: database) else {
            return nil
        }
        
        return obj[keyPath: Through.sortKey].value
    }
    
    // get sortValue of last object
    public func maxSortValue(on database: Database) async throws -> Int? {
        // descending sort to get last obj.
        let lastObj = try await self.$pivots.query(on: database)
            .sort(Through.sortKey, .descending).first()
        
        // when no obj, the first insert value is max/2.
        return lastObj?[keyPath: Through.sortKey].value
    }
}
