//    CKSIncrementalStoreSyncOperation.swift
//
//    The MIT License (MIT)
//
//    Copyright (c) 2015 Nofel Mahmood (https://twitter.com/NofelMahmood)
//
//    Permission is hereby granted, free of charge, to any person obtaining a copy
//    of this software and associated documentation files (the "Software"), to deal
//    in the Software without restriction, including without limitation the rights
//    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//    copies of the Software, and to permit persons to whom the Software is
//    furnished to do so, subject to the following conditions:
//
//    The above copyright notice and this permission notice shall be included in all
//    copies or substantial portions of the Software.
//
//    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//    SOFTWARE.


import UIKit
import CloudKit
import CoreData

let CKSIncrementalStoreSyncOperationErrorDomain = "CKSIncrementalStoreSyncOperationErrorDomain"
let CKSSyncConflictedResolvedRecordsKey = "CKSSyncConflictedResolvedRecordsKey"
let CKSIncrementalStoreSyncOperationFetchChangeTokenKey = "CKSIncrementalStoreSyncOperationFetchChangeTokenKey"


enum CKSStoresSyncConflictPolicy: Int16
{
    case ClientTellsWhichWins = 0
    case ServerRecordWins = 1
    case ClientRecordWins = 2
    case GreaterModifiedDateWins = 3
    case KeepBoth = 4
}

enum CKSStoresSyncError: ErrorType
{
    case LocalChangesFetchError
    case ConflictsDetected
}


class CKSIncrementalStoreSyncOperation: NSOperation {
    
    private var operationQueue:NSOperationQueue?
    private var localStoreMOC:NSManagedObjectContext?
    private var persistentStoreCoordinator:NSPersistentStoreCoordinator?
    private var entities: Array<NSEntityDescription>?
    var syncConflictPolicy:CKSStoresSyncConflictPolicy?
    var syncCompletionBlock:((syncError:NSError?) -> ())?
    var syncConflictResolutionBlock:((clientRecord:CKRecord,serverRecord:CKRecord)->CKRecord)?
    
    init(persistentStoreCoordinator:NSPersistentStoreCoordinator?,entitiesToSync entities:[NSEntityDescription], conflictPolicy:CKSStoresSyncConflictPolicy?) {
        
        self.persistentStoreCoordinator = persistentStoreCoordinator
        self.entities = entities
        self.syncConflictPolicy = conflictPolicy
        super.init()
    }
    
    // MARK: Sync
    override func main() {
        
        self.operationQueue = NSOperationQueue()
        self.operationQueue?.maxConcurrentOperationCount = 1
        
        self.localStoreMOC = NSManagedObjectContext(concurrencyType: NSManagedObjectContextConcurrencyType.PrivateQueueConcurrencyType)
        self.localStoreMOC?.persistentStoreCoordinator = self.persistentStoreCoordinator
        
        if self.syncCompletionBlock != nil
        {
            do
            {
                try self.performSync()
                self.syncCompletionBlock!(syncError: nil)
            }
            catch let error as NSError?
            {
                self.syncCompletionBlock!(syncError: error)
            }
        }
    }
    
    func performSync() throws
    {
        let localChangesInServerRepresentation = try self.localChangesInServerRepresentation()
        var insertedOrUpdatedCKRecords:Array<CKRecord> = localChangesInServerRepresentation.insertedOrUpdatedCKRecords
        let deletedCKRecordIDs:Array<CKRecordID> = localChangesInServerRepresentation.deletedCKRecordIDs
        
        do
        {
            try self.applyLocalChangesToServer(insertedOrUpdatedCKRecords: insertedOrUpdatedCKRecords, deletedCKRecordIDs: deletedCKRecordIDs)
            do
            {
                try self.fetchAndApplyServerChangesToLocalDatabase()
            }
            catch let error as NSError?
            {
                throw error!
            }
        }
        catch let error as NSError?
        {
            let conflictedRecords = error!.userInfo[CKSSyncConflictedResolvedRecordsKey] as! Array<CKRecord>
            self.resolveConflicts(conflictedRecords: conflictedRecords)
            var insertedOrUpdatedCKRecordsWithRecordIDStrings:Dictionary<String,CKRecord> = Dictionary<String,CKRecord>()
            
            for record in insertedOrUpdatedCKRecords
            {
                let ckRecord:CKRecord = record as CKRecord
                insertedOrUpdatedCKRecordsWithRecordIDStrings[ckRecord.recordID.recordName] = ckRecord
            }
            
            for record in conflictedRecords
            {
                insertedOrUpdatedCKRecordsWithRecordIDStrings[record.recordID.recordName] = record
            }
            
            insertedOrUpdatedCKRecords = insertedOrUpdatedCKRecordsWithRecordIDStrings.values.array
    
            try self.applyLocalChangesToServer(insertedOrUpdatedCKRecords: insertedOrUpdatedCKRecords, deletedCKRecordIDs: deletedCKRecordIDs)
            
            do
            {
                try self.fetchAndApplyServerChangesToLocalDatabase()
            }
            catch let error as NSError?
            {
                throw error!
            }
        }
    }
    
    func fetchAndApplyServerChangesToLocalDatabase() throws
    {
        var moreComing = true
        var insertedOrUpdatedCKRecordsFromServer = Array<CKRecord>()
        var deletedCKRecordIDsFromServer = Array<CKRecordID>()
        while moreComing
        {
            let returnValue = self.fetchRecordChangesFromServer()
            insertedOrUpdatedCKRecordsFromServer += returnValue.insertedOrUpdatedCKRecords
            deletedCKRecordIDsFromServer += returnValue.deletedRecordIDs
            moreComing = returnValue.moreComing
        }
        
        try self.applyServerChangesToLocalDatabase(insertedOrUpdatedCKRecordsFromServer, deletedCKRecordIDs: deletedCKRecordIDsFromServer)
    }
    
    // MARK: Local Changes
    func applyServerChangesToLocalDatabase(insertedOrUpdatedCKRecords:Array<CKRecord>,deletedCKRecordIDs:Array<CKRecordID>) throws
    {
        try self.deleteManagedObjects(fromCKRecordIDs: deletedCKRecordIDs)
        try self.insertOrUpdateManagedObjects(fromCKRecords: insertedOrUpdatedCKRecords)
    }
    
    func applyLocalChangesToServer(insertedOrUpdatedCKRecords insertedOrUpdatedCKRecords: Array<CKRecord> , deletedCKRecordIDs: Array<CKRecordID>) throws
    {
        let ckModifyRecordsOperation = CKModifyRecordsOperation(recordsToSave: insertedOrUpdatedCKRecords, recordIDsToDelete: deletedCKRecordIDs)
        
        let savedRecords:[CKRecord] = [CKRecord]()
        var conflictedRecords:[CKRecord] = [CKRecord]()
        ckModifyRecordsOperation.modifyRecordsCompletionBlock = ({(savedRecords,deletedRecordIDs,operationError)->Void in
        })
        ckModifyRecordsOperation.perRecordCompletionBlock = ({(ckRecord,operationError)->Void in
            
            let error:NSError? = operationError
            if error != nil && error!.code == CKErrorCode.ServerRecordChanged.rawValue
            {
                conflictedRecords.append(ckRecord!)
            }
        })
        
        self.operationQueue?.addOperation(ckModifyRecordsOperation)
        self.operationQueue?.waitUntilAllOperationsAreFinished()
        
        if conflictedRecords.count > 0
        {
            throw NSError(domain: CKSIncrementalStoreSyncOperationErrorDomain, code: CKSStoresSyncError.ConflictsDetected._code, userInfo: [CKSSyncConflictedResolvedRecordsKey:conflictedRecords])
        }
        
        if savedRecords.count > 0
        {
            var savedRecordsWithType:Dictionary<String,Dictionary<String,CKRecord>> = Dictionary<String,Dictionary<String,CKRecord>>()
            
            for record in savedRecords
            {
                if savedRecordsWithType[record.recordType] != nil
                {
                    savedRecordsWithType[record.recordType]![record.recordID.recordName] = record
                    continue
                }
                let recordWithRecordIDString:Dictionary<String,CKRecord> = Dictionary<String,CKRecord>()
                savedRecordsWithType[record.recordType] = recordWithRecordIDString
            }
            
            let predicate = NSPredicate(format: "%K IN $recordIDStrings",CKSIncrementalStoreLocalStoreRecordIDAttributeName)
            
            let types = savedRecordsWithType.keys.array
            
            for type in types
            {
                let fetchRequest = NSFetchRequest(entityName: type)
                let ckRecordsForType = savedRecordsWithType[type]
                let ckRecordIDStrings = ckRecordsForType!.keys.array
                
                fetchRequest.predicate = predicate.predicateWithSubstitutionVariables(["recordIDStrings":ckRecordIDStrings])
                var results = try self.localStoreMOC!.executeFetchRequest(fetchRequest)
                if results.count > 0
                {
                    for managedObject in results as! [NSManagedObject]
                    {
                        let ckRecord = ckRecordsForType![managedObject.valueForKey(CKSIncrementalStoreLocalStoreRecordIDAttributeName) as! String]
                        let encodedSystemFields = ckRecord?.encodedSystemFields()
                        managedObject.setValue(encodedSystemFields, forKey: CKSIncrementalStoreLocalStoreRecordEncodedValuesAttributeName)
                    }
                }
            }
            
            try self.localStoreMOC!.save()
        }
    }
    
    func resolveConflicts(conflictedRecords conflictedRecords: Array<CKRecord>)
    {
        if conflictedRecords.count > 0
        {
            var conflictedRecordsWithStringRecordIDs: Dictionary<String,(clientRecord:CKRecord?,serverRecord:CKRecord?)> = Dictionary<String,(clientRecord:CKRecord?,serverRecord:CKRecord?)>()
            
            for record in conflictedRecords
            {
                conflictedRecordsWithStringRecordIDs[record.recordID.recordName] = (record,nil)
            }
            
            let ckFetchRecordsOperation:CKFetchRecordsOperation = CKFetchRecordsOperation(recordIDs: conflictedRecords.map({(object)-> CKRecordID in
                
                let ckRecord:CKRecord = object as CKRecord
                return ckRecord.recordID
            }))
            
            ckFetchRecordsOperation.perRecordCompletionBlock = ({(record,recordID,error)->Void in
                
                if error == nil
                {
                    let ckRecord: CKRecord? = record
                    let ckRecordID: CKRecordID? = recordID
                    if conflictedRecordsWithStringRecordIDs[ckRecordID!.recordName] != nil
                    {
                        conflictedRecordsWithStringRecordIDs[ckRecordID!.recordName] = (conflictedRecordsWithStringRecordIDs[ckRecordID!.recordName]!.clientRecord,ckRecord)
                    }
                }
            })
            self.operationQueue?.addOperation(ckFetchRecordsOperation)
            self.operationQueue?.waitUntilAllOperationsAreFinished()
            
            var finalCKRecords:[CKRecord] = [CKRecord]()
            
            for key in conflictedRecordsWithStringRecordIDs.keys.array
            {
                let value = conflictedRecordsWithStringRecordIDs[key]!
                var clientServerCKRecord = value as (clientRecord:CKRecord?,serverRecord:CKRecord?)
                
                if self.syncConflictPolicy == CKSStoresSyncConflictPolicy.ClientTellsWhichWins
                {
                    if self.syncConflictResolutionBlock != nil
                    {
                        clientServerCKRecord.serverRecord = self.syncConflictResolutionBlock!(clientRecord: clientServerCKRecord.clientRecord!,serverRecord: clientServerCKRecord.serverRecord!)
                    }
                }
                else if (self.syncConflictPolicy == CKSStoresSyncConflictPolicy.ClientRecordWins || (self.syncConflictPolicy == CKSStoresSyncConflictPolicy.GreaterModifiedDateWins && clientServerCKRecord.clientRecord!.modificationDate!.compare(clientServerCKRecord.serverRecord!.modificationDate!) == NSComparisonResult.OrderedDescending))
                {
                    let keys = clientServerCKRecord.serverRecord!.allKeys()
                    let values = clientServerCKRecord.clientRecord!.dictionaryWithValuesForKeys(keys)
                    clientServerCKRecord.serverRecord!.setValuesForKeysWithDictionary(values)
                }
                
                finalCKRecords.append(clientServerCKRecord.serverRecord!)
            }
            
//            let userInfo:Dictionary<String,Array<CKRecord>> = [CKSSyncConflictedResolvedRecordsKey:finalCKRecords]
//            throw NSError(domain: CKSIncrementalStoreSyncOperationErrorDomain, code: CKSStoresSyncError.ConflictsDetected._code, userInfo: userInfo)
        }
    }
    
    func localChangesInServerRepresentation() throws -> (insertedOrUpdatedCKRecords:Array<CKRecord>,deletedCKRecordIDs:Array<CKRecordID>)
    {
        let localChanges = try self.localChanges()
        return (self.insertedOrUpdatedCKRecords(fromManagedObjects: localChanges.insertedOrUpdatedManagedObjects),self.deletedCKRecordIDs(fromManagedObjects: localChanges.deletedManagedObjects))
    }
    
    func localChanges() throws -> (insertedOrUpdatedManagedObjects:Array<AnyObject>,deletedManagedObjects:Array<AnyObject>)
    {
        let entityNames = self.entities!.map( { (entity) -> String in
            return entity.name!
        })
        
        var deletedManagedObjects: Array<AnyObject> = Array<AnyObject>()
        var insertedOrUpdatedManagedObjects: Array<AnyObject> = Array<AnyObject>()
        
        let predicate = NSPredicate(format: "%K != %@", CKSIncrementalStoreLocalStoreChangeTypeAttributeName, NSNumber(short: CKSLocalStoreRecordChangeType.RecordNoChange.rawValue))
        
        for name in entityNames
        {
            let fetchRequest = NSFetchRequest(entityName: name)
            fetchRequest.predicate = predicate
            var results: Array<AnyObject>?
            do
            {
                results = try self.localStoreMOC!.executeFetchRequest(fetchRequest)
                if results!.count > 0
                {
                    insertedOrUpdatedManagedObjects += (results!.filter({(object)->Bool in
                        
                        let managedObject:NSManagedObject = object as! NSManagedObject
                        if (managedObject.valueForKey(CKSIncrementalStoreLocalStoreChangeTypeAttributeName)) as! NSNumber == NSNumber(short: CKSLocalStoreRecordChangeType.RecordUpdated.rawValue)
                        {
                            return true
                        }
                        
                        return false
                    }))
                }
            }
            catch
            {
                throw CKSStoresSyncError.LocalChangesFetchError
            }
        }
        
        do
        {
            let fetchRequest = NSFetchRequest(entityName: CKSDeletedObjectsEntityName)
            deletedManagedObjects = try self.localStoreMOC!.executeFetchRequest(fetchRequest)
        }
        catch
        {
            throw CKSStoresSyncError.LocalChangesFetchError
        }
        
        
        return (insertedOrUpdatedManagedObjects,deletedManagedObjects)
    }
    
    func insertedOrUpdatedCKRecords(fromManagedObjects managedObjects:Array<AnyObject>)  -> Array<CKRecord>
    {
        return managedObjects.map({(object)->CKRecord in
            
            let managedObject:NSManagedObject = object as! NSManagedObject
            let ckRecordID = CKRecordID(recordName: (managedObject.valueForKey(CKSIncrementalStoreLocalStoreRecordIDAttributeName) as! String), zoneID: CKRecordZoneID(zoneName: CKSIncrementalStoreCloudDatabaseCustomZoneName, ownerName: CKOwnerDefaultName))
            
            var ckRecord:CKRecord
            if managedObject.valueForKey(CKSIncrementalStoreLocalStoreRecordEncodedValuesAttributeName) != nil
            {
                let encodedSystemFields = managedObject.valueForKey(CKSIncrementalStoreLocalStoreRecordEncodedValuesAttributeName) as! NSData
                ckRecord = CKRecord.recordWithEncodedFields(encodedSystemFields)
            }
                
            else
            {
                ckRecord = CKRecord(recordType: (managedObject.entity.name)!, recordID: ckRecordID)
            }
            
            let entityAttributes = managedObject.entity.attributesByName.values.array.filter({(object) -> Bool in
                
                let attribute: NSAttributeDescription = object as NSAttributeDescription
                if attribute.name == CKSIncrementalStoreLocalStoreRecordIDAttributeName || attribute.name == CKSIncrementalStoreLocalStoreChangeTypeAttributeName || attribute.name == CKSIncrementalStoreLocalStoreRecordEncodedValuesAttributeName
                {
                    return false
                }
                
                return true
            })
            
            let entityRelationships = managedObject.entity.relationshipsByName.values.array.filter({(object) -> Bool in
                
                let relationship: NSRelationshipDescription = object as NSRelationshipDescription
                return relationship.toMany == false
            })
            
            for attributeDescription in entityAttributes
            {
                if managedObject.valueForKey(attributeDescription.name) != nil
                {
                    switch attributeDescription.attributeType
                    {
                    case .StringAttributeType:
                        ckRecord.setObject(managedObject.valueForKey(attributeDescription.name) as! String, forKey: attributeDescription.name)
                        
                    case .DateAttributeType:
                        ckRecord.setObject(managedObject.valueForKey(attributeDescription.name) as! NSDate, forKey: attributeDescription.name)
                        
                    case .BinaryDataAttributeType:
                        ckRecord.setObject(managedObject.valueForKey(attributeDescription.name) as! NSData, forKey: attributeDescription.name)
                        
                    case .BooleanAttributeType:
                        ckRecord.setObject(managedObject.valueForKey(attributeDescription.name) as! NSNumber, forKey: attributeDescription.name)
                        
                    case .DecimalAttributeType:
                        ckRecord.setObject(managedObject.valueForKey(attributeDescription.name) as! NSNumber, forKey: attributeDescription.name)

                    case .DoubleAttributeType:
                        ckRecord.setObject(managedObject.valueForKey(attributeDescription.name) as! NSNumber, forKey: attributeDescription.name)

                    case .FloatAttributeType:
                        ckRecord.setObject(managedObject.valueForKey(attributeDescription.name) as! NSNumber, forKey: attributeDescription.name)

                    case .Integer16AttributeType:
                        ckRecord.setObject(managedObject.valueForKey(attributeDescription.name) as! NSNumber, forKey: attributeDescription.name)

                    case .Integer32AttributeType:
                        ckRecord.setObject(managedObject.valueForKey(attributeDescription.name) as! NSNumber, forKey: attributeDescription.name)

                    case .Integer64AttributeType:
                        ckRecord.setObject(managedObject.valueForKey(attributeDescription.name) as! NSNumber, forKey: attributeDescription.name)
                    default:
                        break
                    }
                }
            }
            
            for relationshipDescription in entityRelationships as [NSRelationshipDescription]
            {
                if managedObject.valueForKey(relationshipDescription.name) == nil
                {
                    continue
                }
                
                let relationshipManagedObject: NSManagedObject = managedObject.valueForKey(relationshipDescription.name) as! NSManagedObject
                let ckRecordZoneID = CKRecordZoneID(zoneName: CKSIncrementalStoreCloudDatabaseCustomZoneName, ownerName: CKOwnerDefaultName)
                let relationshipCKRecordID = CKRecordID(recordName: relationshipManagedObject.valueForKey(CKSIncrementalStoreLocalStoreRecordIDAttributeName) as! String, zoneID: ckRecordZoneID)
                let ckReference = CKReference(recordID: relationshipCKRecordID, action: CKReferenceAction.DeleteSelf)
                ckRecord.setObject(ckReference, forKey: relationshipDescription.name)
            }
            
            return ckRecord
        })
    }
    
    func deletedCKRecordIDs(fromManagedObjects managedObjects:Array<AnyObject>)->Array<CKRecordID>
    {
        return managedObjects.map({(object)->CKRecordID in
            
            let managedObject:NSManagedObject = object as! NSManagedObject
            let ckRecordID = CKRecordID(recordName: managedObject.valueForKey(CKSIncrementalStoreLocalStoreRecordIDAttributeName) as! String, zoneID: CKRecordZoneID(zoneName: CKSIncrementalStoreCloudDatabaseCustomZoneName, ownerName: CKOwnerDefaultName))
            
            return ckRecordID
        })
    }
    
    func fetchRecordChangesFromServer() -> (insertedOrUpdatedCKRecords:Array<CKRecord>,deletedRecordIDs:Array<CKRecordID>,moreComing:Bool)
    {
        let token = CKSIncrementalStoreSyncOperationTokenHandler.defaultHandler.token()
        let recordZoneID = CKRecordZoneID(zoneName: CKSIncrementalStoreCloudDatabaseCustomZoneName, ownerName: CKOwnerDefaultName)
        let fetchRecordChangesOperation = CKFetchRecordChangesOperation(recordZoneID: recordZoneID, previousServerChangeToken: token)
        
        var insertedOrUpdatedCKRecords: Array<CKRecord> = Array<CKRecord>()
        var deletedCKRecordIDs: Array<CKRecordID> = Array<CKRecordID>()
        
        fetchRecordChangesOperation.fetchRecordChangesCompletionBlock = ({(serverChangeToken,clientChangeToken,operationError)->Void in
            
            if operationError == nil
            {
                CKSIncrementalStoreSyncOperationTokenHandler.defaultHandler.save(serverChangeToken: serverChangeToken!)
                CKSIncrementalStoreSyncOperationTokenHandler.defaultHandler.commit()
            }
        })
        
        fetchRecordChangesOperation.recordChangedBlock = ({(record)->Void in
            
            let ckRecord:CKRecord = record as CKRecord
            insertedOrUpdatedCKRecords.append(ckRecord)
        })
        
        fetchRecordChangesOperation.recordWithIDWasDeletedBlock = ({(recordID)->Void in
            
            deletedCKRecordIDs.append(recordID as CKRecordID)
        })
        
        self.operationQueue?.addOperation(fetchRecordChangesOperation)
        self.operationQueue?.waitUntilAllOperationsAreFinished()
        return (insertedOrUpdatedCKRecords,deletedCKRecordIDs,fetchRecordChangesOperation.moreComing)
    }
    
    func insertOrUpdateManagedObjects(fromCKRecords ckRecords:Array<CKRecord>) throws
    {
        let predicate = NSPredicate(format: "%K == $ckRecordIDString",CKSIncrementalStoreLocalStoreRecordIDAttributeName)
        
        for object in ckRecords
        {
            let ckRecord:CKRecord = object
            let fetchRequest = NSFetchRequest(entityName: ckRecord.recordType)
            fetchRequest.predicate = predicate.predicateWithSubstitutionVariables(["ckRecordIDString":ckRecord.recordID.recordName])
            fetchRequest.fetchLimit = 1
            var results = try self.localStoreMOC!.executeFetchRequest(fetchRequest)
            if results.count > 0
            {
                let managedObject = results.first as! NSManagedObject
                let keys = ckRecord.allKeys().filter({(obj)->Bool in
                    
                    if ckRecord.objectForKey(obj as String) is CKReference
                    {
                        return false
                    }
                    return true
                })
                
                let values = ckRecord.dictionaryWithValuesForKeys(keys)
                managedObject.setValuesForKeysWithDictionary(values)
                managedObject.setValue(NSNumber(short: CKSLocalStoreRecordChangeType.RecordNoChange.rawValue), forKey: CKSIncrementalStoreLocalStoreChangeTypeAttributeName)
                managedObject.setValue(ckRecord.encodedSystemFields(), forKey: CKSIncrementalStoreLocalStoreRecordEncodedValuesAttributeName)
                
                let changedCKReferenceRecordIDStringsWithKeys = ckRecord.allKeys().filter({(obj)->Bool in
                    
                    if ckRecord.objectForKey(obj as String) is CKReference
                    {
                        return true
                    }
                    return false
                    
                }).map({(obj)->(key:String,recordIDString:String) in
                    
                    let key:String = obj as String
                    return (key,(ckRecord.objectForKey(key) as! CKReference).recordID.recordName)
                })
                
                for object in changedCKReferenceRecordIDStringsWithKeys
                {
                    let key = object.key
                    let relationship: NSRelationshipDescription? = managedObject.entity.relationshipsByName[key]
                    let attributeEntityName = relationship!.destinationEntity!.name
                    let fetchRequest = NSFetchRequest(entityName: attributeEntityName!)
                    fetchRequest.predicate = NSPredicate(format: "%K == %@", CKSIncrementalStoreLocalStoreRecordIDAttributeName,object.recordIDString)
                    var results = try self.localStoreMOC!.executeFetchRequest(fetchRequest)
                    if  results.count > 0
                    {
                        managedObject.setValue(results.first, forKey: object.key)
                        break
                    }
                    
                }
            }
            else
            {
                let managedObject:NSManagedObject = NSEntityDescription.insertNewObjectForEntityForName(ckRecord.recordType, inManagedObjectContext: self.localStoreMOC!) as NSManagedObject
                let keys = ckRecord.allKeys().filter({(object)->Bool in
                    
                    let key:String = object as String
                    if ckRecord.objectForKey(key) is CKReference
                    {
                        return false
                    }
                    
                    return true
                })
                
                
                managedObject.setValue(ckRecord.encodedSystemFields(), forKey: CKSIncrementalStoreLocalStoreRecordEncodedValuesAttributeName)
                let changedCKReferencesRecordIDsWithKeys = ckRecord.allKeys().filter({(object)->Bool in
                    
                    let key:String = object as String
                    if ckRecord.objectForKey(key) is CKReference
                    {
                        return true
                    }
                    return false
                    
                }).map({(object)->(key:String,recordIDString:String) in
                    
                    let key:String = object as String
                    
                    return (key,(ckRecord.objectForKey(key) as! CKReference).recordID.recordName)
                })
                
                let values = ckRecord.dictionaryWithValuesForKeys(keys)
                managedObject.setValuesForKeysWithDictionary(values)
                managedObject.setValue(NSNumber(short: CKSLocalStoreRecordChangeType.RecordNoChange.rawValue), forKey: CKSIncrementalStoreLocalStoreChangeTypeAttributeName)
                managedObject.setValue(ckRecord.recordID.recordName, forKey: CKSIncrementalStoreLocalStoreRecordIDAttributeName)
                
                
                for object in changedCKReferencesRecordIDsWithKeys
                {
                    let ckReferenceRecordIDString:String = object.recordIDString
                    let referenceManagedObject = Array(self.localStoreMOC!.registeredObjects).filter({(object)->Bool in
                        
                        let managedObject:NSManagedObject = object as NSManagedObject
                        if (managedObject.valueForKey(CKSIncrementalStoreLocalStoreRecordIDAttributeName) as! String) == ckReferenceRecordIDString
                        {
                            return true
                        }
                        return false
                    }).first
                    
                    if referenceManagedObject != nil
                    {
                        managedObject.setValue(referenceManagedObject, forKey: object.key)
                    }
                    else
                    {
                        let relationshipDescription: NSRelationshipDescription? = managedObject.entity.relationshipsByName[object.key]
                        let destinationRelationshipDescription: NSEntityDescription? = relationshipDescription?.destinationEntity
                        let entityName: String? = destinationRelationshipDescription!.name
                        let fetchRequest = NSFetchRequest(entityName: entityName!)
                        fetchRequest.predicate = NSPredicate(format: "%K == %@", CKSIncrementalStoreLocalStoreRecordIDAttributeName,ckReferenceRecordIDString)
                        fetchRequest.fetchLimit = 1
                        var results = try self.localStoreMOC!.executeFetchRequest(fetchRequest)
                        if results.count > 0
                        {
                            managedObject.setValue(results.first as! NSManagedObject, forKey: object.key)
                            break
                        }
                    }
                }
            }
        }
        
        if self.localStoreMOC!.hasChanges
        {
            try self.localStoreMOC!.save()
        }
        
    }
    
    func deleteManagedObjects(fromCKRecordIDs ckRecordIDs:Array<CKRecordID>) throws
    {
        let predicate = NSPredicate(format: "%K IN $ckRecordIDs",CKSIncrementalStoreLocalStoreRecordIDAttributeName)
        let ckRecordIDStrings = ckRecordIDs.map({(object)->String in
            
            let ckRecordID:CKRecordID = object
            return ckRecordID.recordName
        })
        
        let entityNames = self.entities!.map { (entity) -> String in
            
            return entity.name!
        }
        
        for name in entityNames
        {
            let fetchRequest = NSFetchRequest(entityName: name as String)
            fetchRequest.predicate = predicate.predicateWithSubstitutionVariables(["ckRecordIDs":ckRecordIDStrings])
            var results = try self.localStoreMOC!.executeFetchRequest(fetchRequest)
            if results.count > 0
            {
                for object in results as! [NSManagedObject]
                {
                    self.localStoreMOC?.deleteObject(object)
                }
                
            }
        }
        try self.localStoreMOC?.save()
    }
}