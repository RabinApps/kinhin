import Foundation

/// Static certificates for `TelemetryTLSTests`: two unrelated self-signed CAs and a `localhost` server certificate
/// signed by the first. Generated once, offline (`openssl req -x509` / `openssl x509 -req`, RSA 2048, 800 days from
/// 2026-10-30), with no private key kept: the tests only judge trust, they never serve TLS. Because they expire,
/// the tests pin the verification date to `verifyDate` instead of reading the clock.
enum TelemetryTLSFixtures {
    /// Inside the validity window of every certificate below.
    static let verifyDate = Date(timeIntervalSince1970: 1_811_000_000)  // May 2027

    static let caOne = """
        -----BEGIN CERTIFICATE-----
        MIIDCjCCAfKgAwIBAgIUDQTesLRUdUAiUb0jxb/h8DheQscwDQYJKoZIhvcNAQEL
        BQAwHTEbMBkGA1UEAwwSa2luaGluIHRlc3QgQ0Egb25lMB4XDTI2MTAzMDAzMzM1
        NFoXDTI5MDEwNzAzMzM1NFowHTEbMBkGA1UEAwwSa2luaGluIHRlc3QgQ0Egb25l
        MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAlRbqN1UPz4w0ONn/CNA0
        XNskwDme+ypVjZv/3N0BcMSUzCK0qYZcWp+JtRbH1t49LLQeieQCF7e5kuI2U5R0
        ISt34+8XYmEdP3v4x8vVX3xnj9wqE6tIpdqi2qSEQz2ZxM/NgXRjFuIIZWVmxPGc
        5yN/fVJvVQQqpw3Hw/wSTO/kbqWEwTtRZc1IkPwKPREva0niOooRq+Ko9LJb0uu0
        fTpU+LAlxkb20Cpktp8GhiJRRGCVWOy9R5UahyacaejoIB80q0sWKtjJXNx/V5q7
        u3dwTRbQd7WEk4XKnu0cil5X2TrxtrQDD3Wkdtd22PgSYg37pkQoYryuiywa86b4
        BwIDAQABo0IwQDAdBgNVHQ4EFgQUhkOtr1FnuhSjaevqMtCX5m1HcHcwDwYDVR0T
        AQH/BAUwAwEB/zAOBgNVHQ8BAf8EBAMCAQYwDQYJKoZIhvcNAQELBQADggEBAFt9
        OxCqPxYa+bYmPZrcbbte66Jjf/SmIiBEIZ8cQDCFlZTsmkgKQgPKqDYbm+uYPoQx
        u7i/8Yh+XlyxtNIQ3jGSYefQpHQvprC8qP40JeCrYvylkqC5LtgCJ4er8QQM4SMr
        u17jwg/7NFBzsxGCELkxX2+MYwZtcqjl2srMMnTPoJn3CmniKpHBHBl4SqmOTayu
        Jt/0SPwcMF3Rnym1LTaOfN59z/rbwaBjNtzabElUbGhzqCzcOxP1LieebjG6KktE
        5e6FiZZIm1YxPSJcd+DmwEXnWvKhBQjvjvgORF3tzwj0IK/DE/xKc41ZbES3dTk1
        ZHgmS9uNdacFmxlZFCg=
        -----END CERTIFICATE-----
        """

    static let leafSignedByCAOne = """
        -----BEGIN CERTIFICATE-----
        MIIDBDCCAeygAwIBAgIUQVjnpEY8bwba4oJ06LdE3RGw2OAwDQYJKoZIhvcNAQEL
        BQAwHTEbMBkGA1UEAwwSa2luaGluIHRlc3QgQ0Egb25lMB4XDTI2MTAzMDAzMzM1
        NFoXDTI5MDEwNzAzMzM1NFowFDESMBAGA1UEAwwJbG9jYWxob3N0MIIBIjANBgkq
        hkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAzQq4PWpiX3iDpxcKZpgYOUfA90Nr4Snz
        VYyHN3NacGTRnwpEnohQv00MFywyNCgE9s9AUMGE2hxWhI0rNFGxNXRVMsqnTwsV
        j+2xAuECMY7uTl+GXLIw5G3CjWcEE+SkwvnhsBfTTtJACsmry5JHI/m4bhQJKhgm
        mKaLGHfPh7WHSHW+gasX7V8SQOHpe4WKNl0uyE/oq0gDqtMMg22lsZWzTNxSIm6a
        SUn6F62D64YvgGFnx2faov95SYE51LCUMi5ibby6k+GSYDiI3yijVQ8+Bh30FduX
        /Sdy9bYJfve3peHzEqz7D1mBNSa+IjJfE3i/BKQpM6AH9A3oF5NCYwIDAQABo0Uw
        QzAUBgNVHREEDTALgglsb2NhbGhvc3QwCQYDVR0TBAIwADALBgNVHQ8EBAMCBaAw
        EwYDVR0lBAwwCgYIKwYBBQUHAwEwDQYJKoZIhvcNAQELBQADggEBAAqQ22Hwn/n7
        FrpbmsNQws6gvAwlpVl9DwKJDiWtHkuIPTZRgv1/9N27YFS1aT+MsPFA1mkB2IA+
        PbwYhkTqAdvq8r/sQzDLcPHbIsK+Q4L+q8zlpBHO53L5AW4zyK6rH5ZSd8epUfYW
        5I7E4rQbrbn5UKGFrIqnnU/AL1204sfqURCQ7Nfom3naay1F6lN90BI9ChsNRTyC
        a7YeRpzwOdyhr4he2HFBOcGABIZoEDGVaT7ZR/STVuGzFVE5YpHx6R9lLXVBvIei
        sJbC5t99EHOm1HEu9aBKP0MkbUKMC9GTDaJS0rbmhhXm+WF87SmZDhDbKkDL6pu9
        qZIJUrWWmhg=
        -----END CERTIFICATE-----
        """

    static let caTwo = """
        -----BEGIN CERTIFICATE-----
        MIIDCjCCAfKgAwIBAgIUfVY0saqB8oU1pDnQ7ilfEFpNbVMwDQYJKoZIhvcNAQEL
        BQAwHTEbMBkGA1UEAwwSa2luaGluIHRlc3QgQ0EgdHdvMB4XDTI2MTAzMDAzMzM1
        NFoXDTI5MDEwNzAzMzM1NFowHTEbMBkGA1UEAwwSa2luaGluIHRlc3QgQ0EgdHdv
        MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAwJ4ZlffGrThX7ClGmkZe
        qf+PYEqNlD5ZtJFYz9zLy1/8bBXw1uIvkAJl+G6fcFHc3Cz5BPohiDiEw6mTjNTQ
        O7GRgkoU4K/cEPamVAVR6uc45OMiWXx0Lqk41TjBqscpvKaMjGR/O/FeZcxQM6uu
        KTyiPHpXuD22E2OYlI99Fuh6wkXNm5K+PnBkjDhsna2wg+yEZA6Y0HVpc9xG+weu
        Syp1s4birAtf0u4d7E1VzVnnTY38MbeBFt0+RsLf18UAflGy90OOmkFh+8ijNZaC
        Yewv05BQGtCMDoGUEkSRR0FSCJq0SKQjK8vKRkW9wj7hbJg/Hywao/Szc3JgKJDp
        hQIDAQABo0IwQDAdBgNVHQ4EFgQUBKn855Yff0hdK4vEfa6BTh3xeykwDwYDVR0T
        AQH/BAUwAwEB/zAOBgNVHQ8BAf8EBAMCAQYwDQYJKoZIhvcNAQELBQADggEBAJoh
        usFFcAb22CVQqBoPO5uzCeqTBYJBdj3O7Ap4EM2ZBsQsKmElEc4XJpvZ/VBg8nJa
        SG8ExXGuptAS7fQOSswsObVC5Stjj4/2MMRCqfrEzNhM532Ivd14OZfGTHdslUYk
        1Xn2XtQpC7S/ymi1SGsFEwfJVa3KlfZwm71koqCnOZQY35Bb3E0q6U545003kRko
        IQWif/xLzoGHs9NORsK3EguiAbK1tXdasBUzVcVLi/uqiRReOT+sSPnSgdtRQdep
        aobZFuNUc8oXXWU1XqDKSny0vliBk02zOyNYnTNu3hEk55y9pdxYjTj2sJoxx3qY
        u/M2zW3xBB6owGbFpo4=
        -----END CERTIFICATE-----
        """
}
