# OData v4.01 Implementation TODO

This document tracks missing OData v4.01 protocol features for read-only operations, ordered by relevance for Excel/Power Query compatibility.

## Priority 1: Critical for Excel Compatibility

### ✅ Completed
- [x] Service Document (`/$metadata`)
- [x] Metadata Document (XML/CSDL)
- [x] Entity Set queries (`/collection`)
- [x] Navigation Properties (`/collection(key)/NavProp`)
- [x] Basic `$filter` support (comparison operators)
- [x] Enhanced `$filter` support (logical operators: and/or)
- [x] Foreign Key constraints and metadata generation
- [x] Primary Key constraints
- [x] Dynamic collection groups
- [x] `$expand` System Query Option
- [x] `$select` System Query Option
- [x] `$orderby` System Query Option
- [x] `$top` and `$skip` System Query Options
- [x] `$count` System Query Option
- [x] Server-Driven Paging with `@odata.nextLink`
- [x] Entity by Key access (`/collection(key)`)

### 🔥 Priority 1: Essential Missing Features

**All Priority 1 features have been completed! ✅**

1. **$expand System Query Option** ✅
   - **Current**: Fully implemented with LEFT JOIN support
   - **Features**: Navigation property expansion, nested entity data, integration with other query options
   - **Impact**: Critical for Excel pivot tables with related data
   - **Implementation**: Complete with comprehensive LEFT JOIN SQL generation and test coverage

2. **$select System Query Option** ✅
   - **Current**: Fully implemented with column filtering
   - **Features**: Column selection, context URL updates, integration with other features
   - **Impact**: High - reduces payload size and improves performance
   - **Implementation**: Complete with SQL SELECT wrapping and comprehensive testing

3. **Server-Driven Paging** ✅
   - **Current**: Implemented with configurable page sizes
   - **Features**: `@odata.nextLink`, LIMIT/OFFSET, $skip/$top support
   - **Impact**: High - prevents Excel timeouts on large tables
   - **Implementation**: Complete with comprehensive test coverage

4. **Entity by Key** ✅
   - **Current**: Fully implemented for single entity access
   - **Features**: `GET /customers(1)` returns single customer, works with $expand and $select
   - **Impact**: High - Excel uses this for detail views
   - **Implementation**: Complete with route handling and comprehensive testing

## Priority 2: Important for Advanced Features

5. **$orderby System Query Option** ✅
   - **Current**: Fully implemented with comprehensive support
   - **Features**: Single/multiple column sorting, asc/desc directions, case insensitive
   - **Impact**: Medium - improves user experience in Excel
   - **Implementation**: Complete with SQL ORDER BY generation and integration tests

6. **$top and $skip System Query Options** ✅
   - **Current**: Fully implemented with server-driven paging
   - **Features**: Client and server-driven paging, parameter validation
   - **Impact**: Medium - allows Excel to implement custom paging
   - **Implementation**: Complete with LIMIT/OFFSET SQL generation

7. **$count System Query Option** ✅
   - **Current**: Fully implemented with comprehensive support
   - **Features**: Total count inclusion with `@odata.count`, respects filtering, independent of pagination
   - **Impact**: Medium - helps Excel show total record counts
   - **Implementation**: Complete with COUNT(*) query generation and integration tests

8. **Enhanced $filter Support** ✅ (Partial)
   - **Current**: Comparison operators (eq, ne, gt, ge, lt, le) and logical operators (and, or) implemented
   - **Completed**: Logical operators with proper precedence, complex expressions with parentheses
   - **Still Needed**: Functions (contains, startswith, endswith, etc.) - parser supports but SQL generation needed
   - **Impact**: Medium - enables complex filtering in Excel
   - **Implementation**: NimbleParsec parser complete, SQL generation for functions still needed

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

### Phase 1 (Immediate - Week 1) ✅ COMPLETED
- ✅ Implement $expand for navigation properties
- ✅ Add $select support
- ✅ Implement entity by key access
- ✅ Add server-driven paging with configurable page size

### Phase 2 (Short-term - Week 2-3) ✅ COMPLETED
- ✅ Add $orderby, $top, $skip support
- ✅ Enhance $filter with logical operators
- ✅ Implement $count option
- ⏳ Add $filter functions (contains, startswith, etc.) - parser ready, SQL generation needed

### Phase 3 (Medium-term - Month 1-2)
- Add $search functionality
- Implement entity references
- Enhance context URLs
- Add comprehensive error handling

### Phase 4 (Refactoring - Architecture Improvement)
#### Problem: ODataController Too Heavy (1073 lines)
Current controller has too many responsibilities mixing web and domain logic.

#### Solution: Extract Domain Logic
```
lib/modeta/odata/                    # New OData Domain Context
├── query_builder.ex                # SQL query construction (~300 lines)
├── response_formatter.ex           # OData response formatting (~200 lines)  
├── navigation_resolver.ex          # Navigation property logic (~150 lines)
├── pagination_handler.ex           # Pagination & count logic (~100 lines)
└── parameter_parser.ex             # Parameter parsing & validation (~50 lines)
```

#### Migration Strategy:
1. **Phase 4a**: Extract `QueryBuilder` (build_query_with_options, SQL generation)
2. **Phase 4b**: Extract `ResponseFormatter` (OData JSON formatting, context URLs)
3. **Phase 4c**: Extract `NavigationResolver` (navigation property resolution)
4. **Phase 4d**: Extract smaller modules (`PaginationHandler`, `ParameterParser`)
5. **Phase 4e**: Slim controller (~150-200 lines) + comprehensive tests

#### Benefits:
- Single Responsibility Principle
- Better testability and maintainability  
- Reusable domain logic
- Phoenix conventions (thin controllers)
- Domain-Driven Design separation

### Phase 5 (Long-term - Future)
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