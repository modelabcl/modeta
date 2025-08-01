# OData v4.01 Implementation TODO

This document tracks missing OData v4.01 protocol features for read-only operations, ordered by relevance for Excel/Power Query compatibility.

## Priority 1: Critical for Excel Compatibility

### ✅ Completed
- [x] Service Document (`/$metadata`)
- [x] Metadata Document (XML/CSDL)
- [x] Entity Set queries (`/collection`)
- [x] Navigation Properties (`/collection(key)/NavProp`)
- [x] Basic `$filter` support (comparison operators)
- [x] Foreign Key constraints and metadata generation
- [x] Primary Key constraints
- [x] Dynamic collection groups

### 🔥 Priority 1: Essential Missing Features

1. **$expand System Query Option** 
   - **Current**: Not implemented
   - **Needed**: `GET /purchases?$expand=Customers` should include related customer data inline
   - **Impact**: Critical for Excel pivot tables with related data
   - **Implementation**: Modify query building to JOIN related tables and nest results

2. **$select System Query Option**
   - **Current**: Always returns all columns
   - **Needed**: `GET /purchases?$select=id,total,customer_id` should return only specified fields
   - **Impact**: High - reduces payload size and improves performance
   - **Implementation**: Modify SQL SELECT to include only requested columns

3. **Server-Driven Paging** ✅
   - **Current**: Implemented with configurable page sizes
   - **Features**: `@odata.nextLink`, LIMIT/OFFSET, $skip/$top support
   - **Impact**: High - prevents Excel timeouts on large tables
   - **Implementation**: Complete with comprehensive test coverage

4. **Entity by Key** 
   - **Current**: Navigation properties work, but direct entity access doesn't
   - **Needed**: `GET /customers(1)` should return single customer
   - **Impact**: High - Excel uses this for detail views
   - **Implementation**: Add route and handler for `/:collection(:key)` pattern

## Priority 2: Important for Advanced Features

5. **$orderby System Query Option**
   - **Current**: Natural database order
   - **Needed**: `GET /purchases?$orderby=date desc,total asc`
   - **Impact**: Medium - improves user experience in Excel
   - **Implementation**: Add ORDER BY clause to SQL queries

6. **$top and $skip System Query Options** ✅
   - **Current**: Fully implemented with server-driven paging
   - **Features**: Client and server-driven paging, parameter validation
   - **Impact**: Medium - allows Excel to implement custom paging
   - **Implementation**: Complete with LIMIT/OFFSET SQL generation

7. **$count System Query Option** 
   - **Current**: Not implemented
   - **Needed**: `GET /purchases?$count=true` should include total count
   - **Impact**: Medium - helps Excel show total record counts
   - **Implementation**: Add COUNT(*) query and include in `@odata.count`

8. **Enhanced $filter Support**
   - **Current**: Basic comparison operators only
   - **Needed**: Logical operators (and/or), functions (contains, startswith, etc.)
   - **Impact**: Medium - enables complex filtering in Excel
   - **Implementation**: Enhance ODataFilterParser with full operator support

## Priority 3: Nice to Have

9. **$search System Query Option**
   - **Current**: Not implemented  
   - **Needed**: `GET /customers?$search="John Smith"` for full-text search
   - **Impact**: Low - Excel has its own search capabilities
   - **Implementation**: Add full-text search across all text columns

10. **Context URLs Enhancement**
    - **Current**: Basic context URLs
    - **Needed**: More specific context URLs based on query parameters
    - **Impact**: Low - mainly for debugging and compliance
    - **Implementation**: Generate context URLs based on $select, $expand, etc.

11. **Entity References**
    - **Current**: Not implemented
    - **Needed**: `GET /purchases(1)/Customers/$ref` returns reference URIs only
    - **Impact**: Low - rarely used by Excel
    - **Implementation**: Add $ref endpoint returning just @odata.id values

12. **Singletons Support**
    - **Current**: Not implemented
    - **Needed**: Single entity endpoints like `/DatabaseInfo`
    - **Impact**: Low - not commonly used
    - **Implementation**: Add singleton configuration to collections.yml

## Priority 4: Advanced/Optional Features

13. **Function Imports**
    - **Current**: Not implemented
    - **Needed**: Custom functions like `/CalculateTotalSales(year=2023)`
    - **Impact**: Very Low - Excel rarely uses custom functions
    - **Implementation**: Add function definition and execution framework

14. **Delta Links**
    - **Current**: Not implemented
    - **Needed**: Track changes with `$deltatoken`
    - **Impact**: Very Low - Excel doesn't typically use delta queries
    - **Implementation**: Add change tracking and delta response generation

15. **Batch Requests**
    - **Current**: Not implemented
    - **Needed**: Multiple operations in single HTTP request
    - **Impact**: Very Low - Excel sends individual requests
    - **Implementation**: Add batch request parsing and execution

## Implementation Strategy

### Phase 1 (Immediate - Week 1)
- Implement $expand for navigation properties
- Add $select support
- Implement entity by key access
- Add server-driven paging with configurable page size

### Phase 2 (Short-term - Week 2-3)  
- Add $orderby, $top, $skip support
- Implement $count option
- Enhance $filter with logical operators and functions

### Phase 3 (Medium-term - Month 1-2)
- Add $search functionality
- Implement entity references
- Enhance context URLs
- Add comprehensive error handling

### Phase 4 (Long-term - Future)
- Function imports for custom business logic
- Delta query support
- Batch request handling

## Testing Strategy

Each feature should be tested with:
1. **Unit tests** for parser and SQL generation
2. **Integration tests** with actual DuckDB queries  
3. **Excel compatibility tests** using Power Query
4. **Performance tests** with large datasets

## Notes

- All implementations should maintain backward compatibility
- Error responses should follow OData error format
- URL encoding/decoding must be handled properly
- All features should work with the existing dynamic collection system
- Consider memory usage with large result sets
- Ensure proper SQL injection prevention