// OAuth provider interface (guide §11.2).
//
// Every OAuth provider implements four operations: build the authorize
// URL (given a PKCE code_verifier and redirect_uri), exchange an
// authorization code for tokens, refresh an existing refresh token, and
// expose its own short name.

export interface TokenSet {
  accessToken: string;
  refreshToken: string;
  /// Seconds until expiration, as returned by the upstream.
  expiresIn: number;
  /// Required. Extracted from the access_token JWT for chatgpt-plan; the
  /// downstream Codex API rejects calls that lack it. We refuse to store a
  /// token without an accountId rather than silently saving a credential
  /// that won't authorize real LLM calls.
  accountId: string;
}

export interface AuthorizeOptions {
  codeVerifier: string;
  redirectUri: string;
  state: string;
}

export interface ExchangeOptions {
  code: string;
  codeVerifier: string;
  redirectUri: string;
  signal?: AbortSignal;
}

export interface OAuthProviderInterface {
  name: string;
  buildAuthorizeUrl(opts: AuthorizeOptions): string;
  exchangeCode(opts: ExchangeOptions): Promise<TokenSet>;
  refresh(refreshToken: string, opts?: { signal?: AbortSignal }): Promise<TokenSet>;
}
