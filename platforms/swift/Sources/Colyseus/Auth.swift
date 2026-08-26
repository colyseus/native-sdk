import CColyseus
import Foundation

public extension Colyseus {
    /// Sign-in, registration, and the token they produce.
    ///
    /// The token is stored in the system keychain and reused across launches,
    /// and it is the same token ``Colyseus/HTTP`` sends. That storage is
    /// process-wide and survives the process, so a test that signs in has to
    /// sign out.
    final class Auth: @unchecked Sendable {
        // An opaque C struct, so Swift sees a bare pointer.
        private let raw: OpaquePointer?
        private let http: HTTP
        private let changed = Emitter<User?>()
        private var changeBridge: UnsafeMutableRawPointer?

        /// The route the auth module is mounted on, `/auth` by default.
        public var path: String = "/auth" {
            didSet {
                guard let raw else { return }
                path.withCString { colyseus_auth_set_path(raw, $0) }
            }
        }

        /// The keychain key the token is stored under.
        public var storageKey: String = "colyseus-auth-token" {
            didSet {
                guard let raw else { return }
                storageKey.withCString { colyseus_auth_set_storage_key(raw, $0) }
            }
        }

        init(_ raw: OpaquePointer?, http: HTTP) {
            self.raw = raw
            self.http = http
        }

        deinit {
            releasePointer(changeBridge, as: Emitter<User?>.self)
        }

        /// A signed-in user: the token, and whatever the server said about them.
        public struct User: Sendable {
            public let token: String
            /// The server's user record, as it sent it.
            public let data: MessagePackValue

            /// Nil means signed out: that is how the core reports it, with a
            /// change carrying no token rather than no change at all.
            init?(_ raw: UnsafePointer<colyseus_auth_data_t>?) {
                guard let raw, let token = String(nullableCString: raw.pointee.token), !token.isEmpty
                else { return nil }
                self.token = token
                data = String(nullableCString: raw.pointee.user_json)
                    .flatMap { text in
                        text.data(using: .utf8)
                            .flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) }
                    }
                    .map(MessagePackValue.init(json:)) ?? .null
            }
        }

        /// The current token, if any. Setting it to nil signs out locally.
        public var token: String? {
            get { raw.flatMap { String(nullableCString: colyseus_auth_get_token($0)) } }
            set {
                guard let raw else { return }
                if let newValue {
                    newValue.withCString { colyseus_auth_set_token(raw, $0) }
                } else {
                    colyseus_auth_set_token(raw, nil)
                }
            }
        }

        /// Called whenever the signed-in user changes, sign-out included.
        @discardableResult
        public func onChange(_ handler: @escaping @Sendable (User?) -> Void) -> Subscription {
            if changeBridge == nil, let raw {
                let pointer = retainedPointer(changed)
                changeBridge = pointer
                colyseus_auth_on_change(raw, { data, userdata in
                    borrowObject(userdata, as: Emitter<User?>.self)?.emit(User(data))
                }, pointer)
            }
            return changed.add(handler)
        }

        // MARK: - Flows

        public func signInAnonymously(options: MessagePackValue = [:]) async throws -> User {
            try await call { raw, optionsJSON, onSuccess, onError, userdata in
                colyseus_auth_signin_anonymous(raw, optionsJSON, onSuccess, onError, userdata)
            }(options)
        }

        public func register(email: String, password: String, options: MessagePackValue = [:]) async throws -> User {
            try await withUser { onSuccess, onError, userdata in
                guard let raw else { return false }
                withCStrings([email, password, options.jsonString ?? "{}"]) { strings in
                    colyseus_auth_register_email_password(
                        raw, strings[0], strings[1], strings[2], onSuccess, onError, userdata
                    )
                }
                return true
            }
        }

        public func signIn(email: String, password: String) async throws -> User {
            try await withUser { onSuccess, onError, userdata in
                guard let raw else { return false }
                withCStrings([email, password]) { strings in
                    colyseus_auth_signin_email_password(raw, strings[0], strings[1], onSuccess, onError, userdata)
                }
                return true
            }
        }

        /// Re-read the signed-in user from the server, using the stored token.
        public func userData() async throws -> User {
            try await withUser { onSuccess, onError, userdata in
                guard let raw else { return false }
                colyseus_auth_get_user_data(raw, onSuccess, onError, userdata)
                return true
            }
        }

        public func sendPasswordReset(email: String) async throws {
            _ = try await withUser { onSuccess, onError, userdata in
                guard let raw else { return false }
                email.withCString { colyseus_auth_send_password_reset(raw, $0, onSuccess, onError, userdata) }
                return true
            }
        }

        /// Forget the token, here and in the keychain.
        public func signOut() {
            guard let raw else { return }
            colyseus_auth_signout(raw)
        }

        // MARK: -

        private func call(
            _ body: @escaping (
                OpaquePointer,
                UnsafePointer<CChar>?,
                colyseus_auth_success_callback_t?,
                colyseus_auth_error_callback_t?,
                UnsafeMutableRawPointer?
            ) -> Void
        ) -> (MessagePackValue) async throws -> User {
            { options in
                try await self.withUser { onSuccess, onError, userdata in
                    guard let raw = self.raw else { return false }
                    (options.jsonString ?? "{}").withCString { optionsPointer in
                        body(raw, optionsPointer, onSuccess, onError, userdata)
                    }
                    return true
                }
            }
        }

        private func withUser(
            _ start: (
                colyseus_auth_success_callback_t?,
                colyseus_auth_error_callback_t?,
                UnsafeMutableRawPointer?
            ) -> Bool
        ) async throws -> User {
            try await withCheckedThrowingContinuation { continuation in
                let box = OneShot<User> { continuation.resume(with: $0) }
                let pointer = retainedPointer(box)

                let started = start({ data, userdata in
                    let box = consumeObject(userdata, as: OneShot<User>.self)
                    if let user = User(data) {
                        box?.finish(.success(user))
                    } else {
                        box?.finish(.failure(Colyseus.Error.auth("server returned no user")))
                    }
                }, { message, userdata in
                    consumeObject(userdata, as: OneShot<User>.self)?
                        .finish(.failure(Colyseus.Error.auth(String(nullableCString: message) ?? "unknown error")))
                }, pointer)

                if !started {
                    releasePointer(pointer, as: OneShot<User>.self)
                    continuation.resume(throwing: Colyseus.Error.unavailable("client has been released"))
                }
            }
        }
    }
}
