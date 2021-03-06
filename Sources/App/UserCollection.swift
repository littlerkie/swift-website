import Vapor
import FluentMySQLDriver

class UserCollection: ApiCollection {
    
    typealias T = User
    
    struct SupportedQueries: Decodable {
        var includeExperience: Bool?
        var includeEducation: Bool?
        var includeSNS: Bool?
        var includeProjects: Bool?
        var includeSkill: Bool?
        var includeBlog: Bool?
        
        enum CodingKeys: String, CodingKey {
            case includeExperience = "incl_wrk_exp"
            case includeEducation = "incl_edu_exp"
            case includeSNS = "incl_sns"
            case includeProjects = "incl_projs"
            case includeSkill = "incl_skill"
            case includeBlog = "incl_blog"
        }
    }
    
    func boot(routes: RoutesBuilder) throws {
        
        let users = routes.grouped(.constant(path))
        
        users.on(.POST, use: create)
        users.on(.GET, use: readAll)
        users.on(.GET, .parameter(restfulIDKey), use: read)
        users.on(.GET, .parameter(restfulIDKey), "blog", use: readAllBlog)
        users.on(.GET, .parameter(restfulIDKey), "resume", use: readResume)
        
        let trusted = users.grouped([
            User.authenticator(),
            Token.authenticator(),
            User.guardMiddleware()
        ])
        trusted.on(.PUT, .parameter(restfulIDKey), use: update)
        trusted.on(.DELETE, .parameter(restfulIDKey), use: delete)
        trusted.on(.PATCH, .parameter(restfulIDKey), "profile_image", body: .collect(maxSize: "100kb"), use: patch)
        trusted.on(.POST, .parameter(restfulIDKey), "social_networking", use: createSocialNetworking)
    }
    
    /// Register new user with `User.Creation` msg.
    /// - seealso: `User.Creation` for more creation content info.
    /// - note: We make `username` unique so if the `username` already taken an `conflic` statu will be
    /// send to custom.
    func create(_ req: Request) throws -> EventLoopFuture<T.DTO> {
        try User.Creation.validate(content: req)
        
        let user = try T.init(req.content.decode(User.Creation.self))
                
        return user.save(on: req.db)
            .flatMapErrorThrowing({
                if case MySQLError.duplicateEntry = $0 {
                    throw Abort.init(.unprocessableEntity, reason: "Value for key 'username' already exsit.")
                }
                throw $0
            })
            .flatMapThrowing({
                try user.dataTransferObject()
            })
    }
    
    /// Query user with specified`userID`.
    /// - seealso: `readAll(_:)`
    func read(_ req: Request) throws -> EventLoopFuture<T.DTO> {
        let supportedQueries = try req.query.decode(SupportedQueries.self)

        var builder = try specifiedIDQueryBuilder(on: req)
        builder = applyingFields(builder)
        builder = applyingEagerLoaders(builder, with: supportedQueries)
        
        return builder
            .first()
            .unwrap(orError: Abort(.notFound))
            .flatMapThrowing({
                try $0.dataTransferObject()
            })
    }
    
    func readAll(_ req: Request) throws -> EventLoopFuture<[T.DTO]> {
        let supportedQueries = try req.query.decode(SupportedQueries.self)

        var builder = T.query(on: req.db)
        builder = applyingFieldsForQueryAll(builder)
        builder = applyingEagerLoadersForQueryAll(builder, with: supportedQueries)
        
        return builder
            .all()
            .flatMapEachThrowing({
                try $0.dataTransferObject()
            })
    }

    
    /// Update exists user with `User.Coding` which contain all properties that user need updated.
    func update(_ req: Request) throws -> EventLoopFuture<T.DTO> {
        let userId = try req.auth.require(User.self).requireID()
        let coding = try req.content.decode(User.Coding.self)
        
        return User.find(userId, on: req.db)
            .unwrap(or: Abort.init(.notFound))
            .flatMap({ saved -> EventLoopFuture<User> in
                do {
                return try saved.update(with: coding)
                    .update(on: req.db)
                    .map({ saved })
                } catch {
                    return req.eventLoop.makeFailedFuture(error)
                }
            })
            .flatMapThrowing({
                try $0.dataTransferObject()
            })
    }
    
    func patch(_ req: Request) throws -> EventLoopFuture<T.DTO> {
        let userId = try req.auth.require(User.self).requireID()
        
        return T.find(userId, on: req.db)
            .unwrap(or: Abort.init(.notFound))
            .flatMap({ saved -> EventLoopFuture<User> in
                do {
                    return try uploadImageFile(req)
                        .flatMap({
                            saved.avatarUrl = $0
                            return saved.update(on: req.db).map({ saved })
                        })
                } catch {
                    return req.eventLoop.makeFailedFuture(error)
                }
            })
            .flatMapThrowing({
                try $0.dataTransferObject()
            })
    }
    
    func specifiedIDQueryBuilder(on req: Request) throws -> QueryBuilder<T> {
        let builder = T.query(on: req.db)
        
        if let id = req.parameters.get(restfulIDKey, as: User.IDValue.self) {
            builder.filter(\._$id == id)
        } else if let id = req.parameters.get(restfulIDKey) {
            builder.filter(User.FieldKeys.username, .equal, id)
        } else {
            if req.parameters.get(restfulIDKey) != nil {
                throw Abort(.unprocessableEntity)
            } else {
                throw Abort(.internalServerError)
            }
        }
        
        return builder
    }
    
    func applyingEagerLoaders(
        _ builder: QueryBuilder<T>,
        with supportedQueries: SupportedQueries
    ) -> QueryBuilder<T> {
        applyingEagerLoadersForQueryAll(builder, with: supportedQueries)
    }
    
    func applyingEagerLoadersForQueryAll(
        _ builder: QueryBuilder<T>,
        with supportedQueries: SupportedQueries
    ) -> QueryBuilder<T> {
        if supportedQueries.includeExperience ?? false {
            builder.with(\.$experiences) {
                $0.with(\.$industries)
            }
        }
        
        if supportedQueries.includeEducation ?? false {
            builder.with(\.$education)
        }
        
        if supportedQueries.includeSNS ?? false {
            builder.with(\.$social) {
                $0.with(\.$service)
            }
        }
        
        if supportedQueries.includeProjects ?? false {
            builder.with(\.$projects)
        }
        
        if supportedQueries.includeSkill ?? false {
            builder.with(\.$skill)
        }
        
        if supportedQueries.includeBlog ?? false {
            builder.with(\.$blog) {
                $0.with(\.$categories)
            }
        }
        
        return builder
    }
}

// MARK: Blog
extension UserCollection {
    func readAllBlog(_ req: Request) throws -> EventLoopFuture<[Blog.DTO]> {
        try specifiedIDQueryBuilder(on: req)
            .first()
            .unwrap(or: Abort(.notFound))
            .flatMap({
                return BlogCollection.init()
                    .applyingFieldsForQueryAll($0.$blog.query(on: req.db))
                    .all()
            })
            .flatMapEachThrowing({
                try $0.dataTransferObject()
            })
    }
}

// MARK: CV
extension UserCollection {
    func readResume(_ req: Request) throws -> EventLoopFuture<T.DTO> {
        try specifiedIDQueryBuilder(on: req)
            .with(\.$projects)
            .with(\.$education)
            .with(\.$experiences) {
                $0.with(\.$industries)
            }
            .with(\.$social) {
                $0.with(\.$service)
            }
            .with(\.$skill)
            .first()
            .unwrap(or: Abort(.notFound))
            .flatMapThrowing({
                try $0.dataTransferObject()
            })
    }
}

// MARK: Social Networking
extension UserCollection {
    func createSocialNetworking(_ request: Request) throws -> EventLoopFuture<SocialNetworking.DTO> {
        let serializedObject = try request.content.decode(SocialNetworking.DTO.self)
        
        let model = try SocialNetworking(from: serializedObject)
        model.$user.id = try request.auth.require(User.self).requireID()
        
        return model
            .save(on: request.db)
            .flatMap({
                model.$service.load(on: request.db)
            })
            .flatMapThrowing({
                try model.dataTransferObject()
            })
    }
}
