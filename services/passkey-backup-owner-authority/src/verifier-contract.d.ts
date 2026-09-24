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
  readonly authenticatorAttachment?: 'platform' | 'cross-platform';
  readonly clientExtensionResults: Record<string, unknown>; // Runtime accepts only empty or public credProps.rk.
  readonly response: {
    readonly clientDataJSON: string;
    readonly attestationObject?: string;
    readonly publicKeyAlgorithm?: -7 | -257;
    readonly publicKey?: string;
    readonly transports?: readonly ('ble' | 'cable' | 'hybrid' | 'internal' | 'nfc' | 'smart-card' | 'usb')[];
    readonly authenticatorData?: string;
    readonly signature?: string;
    readonly userHandle?: string | null;
  };
}
export interface ClaimedCredentialChallenge {
  readonly challengeId: string; // Durable, claimed SQLite row ID.
  readonly kind: 'registration' | 'assertion';
  readonly challenge: string; // Exact 32-byte server nonce, base64url.
  readonly rpId: 'fearlesswallet.io';
  readonly platform: Platform; // Selected from the authenticated session.
  readonly userHandle: string; // Historical per-storage-key handle.
  readonly directedCredentialId: string | null;
  readonly credentialId: string;
  readonly registeredCredential: CredentialRecord | null; // Public verification key/counter for assertion.
  readonly expiresAt: number;
}
export interface RegistrationMutationEvidence {
  readonly challengeNonce: string;
  readonly platform: Platform;
  readonly credential: CredentialRecord;
  readonly aaguid: string;
  readonly transportsJson: string | null;
}
export interface AssertionMutationEvidence {
  readonly challengeNonce: string;
  readonly platform: Platform;
  readonly expectedCounter: number;
  readonly newCounter: number;
  readonly deviceType: 'singleDevice' | 'multiDevice';
  readonly backedUp: boolean;
}
export interface LegacyCutoverAssertionEvidence {
  readonly role: 'LEGACY' | 'OWNER';
  readonly challenge: string;
  readonly credentialId: string;
  readonly expectedCounter: number;
  readonly newCounter: number;
  readonly deviceType: 'singleDevice' | 'multiDevice';
  readonly backedUp: boolean;
}
export interface WalletProof {
  readonly scheme: 'ed25519' | 'sr25519' | 'secp256k1';
  readonly publicKey: string;
  readonly signature: string;
}
export type AppAttestation =
  | { readonly kind: 'play-integrity'; readonly token: string }
  | { readonly kind: 'app-attest'; readonly keyId: string; readonly attestationObject: string };
export interface BootstrapAdmission {
  readonly android: {
    readonly packageName: string;
    readonly signingCertificateSha256: string; // Lowercase hex of the Play signing certificate.
  };
  readonly ios: {
    readonly teamId: string;
    readonly bundleId: string;
  };
  /** Server-owned implementation; must verify platform certificate/token and the exact nonce. */
  verifyAppAttestation(input: {
    readonly platform: Platform;
    readonly expectedNonce: string; // SHA-256 nonce bound to signed wallet proof and registration.
    readonly expectedApplication: string;
    readonly attestation: AppAttestation;
  }): Promise<{ readonly platform: Platform; readonly nonce: string; readonly application: string }>;
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
    readonly appAttestation: AppAttestation;
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
  /**
   * Server-only v5 route adapters. The owner core durably claims the exact
   * response first, invokes these methods, then rechecks claim/grant/credential
   * under one SQLite writer lock. Direct adapter calls grant no authority.
   */
  challengeRegistration?(input: {
    readonly ceremony: ClaimedCredentialChallenge;
    readonly credential: PublicCredentialResponse;
  }): Promise<RegistrationMutationEvidence>;
  challengeAssertion?(input: {
    readonly ceremony: ClaimedCredentialChallenge;
    readonly credential: PublicCredentialResponse;
  }): Promise<AssertionMutationEvidence>;
  /** Verify one role of a claimed v7 cutover pair against server-read public material. */
  legacyCutoverAssertion?(input: {
    readonly role: 'LEGACY' | 'OWNER';
    readonly challenge: string;
    readonly rpId: 'fearlesswallet.io';
    readonly platform: Platform;
    readonly credential: PublicCredentialResponse;
    readonly registeredCredential: CredentialRecord;
  }): Promise<LegacyCutoverAssertionEvidence>;
}
