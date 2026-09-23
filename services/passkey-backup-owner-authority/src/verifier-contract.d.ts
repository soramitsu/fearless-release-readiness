/** Server composition interface only. Never deserialize this from a client or env JSON. */
export type Platform = 'android' | 'ios';
export type CeremonyKind = 'bootstrap' | 'authentication' | 'enrollment';
export interface Ceremony {
  readonly ceremonyId: string;
  readonly kind: CeremonyKind;
  readonly challenge: string;
  readonly rpId: 'fearlesswallet.io';
  readonly platform: Platform;
  readonly subject: string;
  readonly namespace: string;
  readonly userHandle: string;
  readonly expiresAt: number;
}
export interface CredentialRecord {
  readonly id: string; // Canonical base64url credential ID.
  readonly publicKey: string; // Canonical base64url COSE verification public key.
  readonly userHandle: string; // Exact persisted value, not a caller owner hint.
  readonly counter: number;
  readonly deviceType: 'singleDevice' | 'multiDevice';
  readonly backedUp: boolean;
}
export interface PublicCredentialResponse {
  readonly id: string;
  readonly rawId: string;
  readonly type: 'public-key';
  readonly clientExtensionResults: Record<string, unknown>; // Runtime accepts only empty or public credProps.rk.
  readonly response: {
    readonly clientDataJSON: string;
    readonly attestationObject?: string;
    readonly authenticatorData?: string;
    readonly signature?: string;
    readonly userHandle?: string;
  };
}
export interface WalletProof {
  readonly scheme: 'ed25519' | 'sr25519' | 'secp256k1';
  readonly publicKey: string;
  readonly signature: string;
}
export interface CryptographicVerifier {
  /**
   * Verify fresh self-custody wallet proof AND first WebAuthn credential.
   * Bind wallet proof to this server nonce, owner, userHandle, RP, platform and
   * a domain-separated digest of the complete new registration response.
   * walletBindingHash is server-derived from a normalized wallet public key and
   * scheme, never Google ID, caller walletId, owner hint or unverified hash.
   */
  bootstrap(input: {
    readonly ceremony: Ceremony;
    readonly credential: PublicCredentialResponse;
    readonly walletProof: WalletProof;
  }): Promise<{ readonly credential: CredentialRecord; readonly walletBindingHash: string }>;
  /**
   * Verify exact server challenge, RP, qualified platform origin, UV/UP,
   * signature, persisted userHandle/COSE key, counter and BE/BS consistency.
   * No account lookup, identity reassignment, Google token or PRF possession is
   * a substitute. The core rechecks linkage/revocation/counter in its commit.
   */
  authentication(input: {
    readonly ceremony: Ceremony;
    readonly credential: PublicCredentialResponse;
    readonly registeredCredential: CredentialRecord;
  }): Promise<{
    readonly credentialId: string; readonly newCounter: number;
    readonly deviceType: 'singleDevice' | 'multiDevice'; readonly backedUp: boolean;
  }>;
  /** Verify new WebAuthn registration for the exact server session/owner ceremony. */
  enrollment(input: {
    readonly ceremony: Ceremony;
    readonly credential: PublicCredentialResponse;
  }): Promise<{ readonly credential: CredentialRecord }>;
}
