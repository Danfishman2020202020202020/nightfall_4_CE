// SPDX-License-Identifier: CC0-1.0

pragma solidity ^0.8.3;

// This contract can parse  a suitably encoded SSL certificate
import './DerParser.sol';
import './Allowlist.sol';
import './X509Interface.sol';
import './Sha.sol';
contract X509 is DERParser, Allowlist, Sha, X509Interface {
    uint256 constant SECONDS_PER_DAY = 24 * 60 * 60;
    int256 constant OFFSET19700101 = 2440588;

    struct RSAPublicKey {
        bytes modulus;
        uint256 exponent;
    }

    struct CertificateArgs {
    bytes certificate;
    uint256 tlvLength;
    bytes addressSignature;
    bool isEndUser;
    bool checkOnly;
    uint256 oidGroup;
    address addr;
}

    mapping(address => uint256) expires;
    mapping(bytes32 => RSAPublicKey) trustedPublicKeys;
    mapping(bytes32 => bool) revokedKeys;
    mapping(address => bytes32) keysByUser;
    // Reverse mapping to ensure one certificate is tied to one address
    mapping(bytes32 => address) addressByKey; 

    bytes32[][] extendedKeyUsageOIDs; // this is an array of arrays because each CA has their own set of OIDs that they use
    bytes32[][] certificatePoliciesOIDs; // this is an array of arrays because each CA has their own set of OIDs that they use

    bytes1 usageBitMaskEndUser;
    bytes1 usageBitMaskIntermediate;

     constructor(
        address owner_
    ) Allowlist(owner_) {
        usageBitMaskEndUser = 0x80;
        usageBitMaskIntermediate = 0x06;
    }

    function setUsageBitMaskEndUser(bytes1 _usageBitMask) external onlyOwner {
        usageBitMaskEndUser = _usageBitMask;
    }

    function setUsageBitMasIntermediate(bytes1 _usageBitMask) external onlyOwner {
        usageBitMaskIntermediate = _usageBitMask;
    }

    function addExtendedKeyUsage(bytes32[] calldata oids) external onlyOwner {
        extendedKeyUsageOIDs.push(oids);
    }

    function addCertificatePolicies(bytes32[] calldata oids) external onlyOwner {
        certificatePoliciesOIDs.push(oids);
    }

    // NB this function removes everything.  You need to re-add all oids if you call this but removing
    // everything has the advantage of not creating a sparse array, which would happend if we deleted
    // individual elements. Of course it is unlikely that this function will ever be needed.
    function removeExtendedKeyUsage() external onlyOwner {
        delete extendedKeyUsageOIDs;
    }

    function removeCertificatePolicies() external onlyOwner {
        delete certificatePoliciesOIDs;
    }

    function setTrustedPublicKey(
        RSAPublicKey calldata trustedPublicKey,
        uint256 _authorityKeyIdentifier
    ) external onlyOwner {
        bytes32 authorityKeyIdentifier = bytes32(_authorityKeyIdentifier);
        trustedPublicKeys[authorityKeyIdentifier] = trustedPublicKey;
    }

    function getSignature(
        DecodedTlv[] memory tlvs,
        uint256 maxId
    ) private pure returns (bytes memory) {
        DecodedTlv memory signatureTlv = tlvs[maxId - 1];
        require(signatureTlv.depth == 1, 'X509: Signature tlv depth is incorrect');
        require(
            signatureTlv.tag.tagType == 0x03,
            'X509: Signature tlv should have a tag type of BIT STRING'
        );
        bytes memory signature = signatureTlv.value;
        return signature;
    }

    function getMessage(DecodedTlv[] memory tlvs) private pure returns (bytes memory) {
        DecodedTlv memory messageTlv = tlvs[1];
        require(messageTlv.depth == 1, 'X509: Message tlv depth is incorrect');
        require(
            messageTlv.tag.tagType == 0x10,
            'X509: Message tlv should have a tag type of BIT STRING'
        );
        bytes memory message = messageTlv.octets;
        return message;
    }

    // given a base b, an exponent e and a modulus m, this function returns b^e mod m
    function modExp(
        bytes memory b,
        uint256 e,
        bytes memory m
    ) internal view returns (bytes memory) {
        bool success;
        bytes memory result;
        (success, result) = (
            address(5).staticcall(abi.encodePacked(b.length, uint256(32), m.length, b, e, m))
        );
        require(success, 'X509: modExp error');
        return result;
    }

    /*
    Validate the decrypted signature and returns the message hash
    */
    function validateSignatureAndExtractMessageHash(
        bytes memory decrypt,
        uint256 tlvLength
    ) private view returns (bytes memory) {
        DecodedTlv[] memory tlvs = new DecodedTlv[](tlvLength);
        require(
            decrypt[0] == 0x00 && decrypt[1] == 0x00,
            'X509: Decrypt does not have a leading zero octets'
        );
        require(
            decrypt[2] == 0x00 || decrypt[2] == 0x01,
            'X509: Block Type is not a private key operation'
        );
        // loop through the padding
        uint256 i;
        for (i = 3; i < decrypt.length; i++) {
            if (decrypt[i] != 0xff) break;
        }
        i++;
        tlvs = this.parseDER(decrypt, i, tlvLength);
        require(
            tlvs[4].depth == 1 && tlvs[4].tag.tagType == 0x04,
            'X509: Incorrect tag or position for decrypted hash data'
        );
        bytes memory messageHashFromSignature = tlvs[4].value;
        return messageHashFromSignature;
    }

    // note: this function is from an MIT licensed library, with appreciation to
    // https://github.com/bokkypoobah/BokkyPooBahsDateTimeLibrary/blob/v1.01/contracts/BokkyPooBahsDateTimeLibrary.sol
    // minor changes made
    function timestampFromDate(bytes memory utcTime) private pure returns (uint256 _seconds) {
        uint256 year = uint256(uint8(utcTime[0]) - 48) *
            10 +
            uint256(uint8(utcTime[1]) - 48) +
            2000;
        uint256 month = uint256(uint8(utcTime[2]) - 48) * 10 + uint256(uint8(utcTime[3]) - 48);
        uint256 day = uint256(uint8(utcTime[4]) - 48) * 10 + uint256(uint8(utcTime[5]) - 48);
        require(year >= 1970);
        int256 _year = int256(year);
        int256 _month = int256(month);
        int256 _day = int256(day);

        int256 __days = _day -
            32075 +
            (1461 * (_year + 4800 + (_month - 14) / 12)) /
            4 +
            (367 * (_month - 2 - ((_month - 14) / 12) * 12)) /
            12 -
            (3 * ((_year + 4900 + (_month - 14) / 12) / 100)) /
            4 -
            OFFSET19700101;

        _seconds = uint256(__days) * SECONDS_PER_DAY;
    }

    // this function finds and checks the Not Before and Not After tlvs
    function checkDates(DecodedTlv[] memory tlvs) private view returns (uint256) {
        // The Not Before and Not After dates are the third SEQUENCE at depth 2
        uint256 i;
        uint256 j;
        for (i = 0; i < tlvs.length; i++) {
            if (tlvs[i].tag.tagType == 0x10 && tlvs[i].depth == 2) j++;
            if (j == 3) break;
        }
        require(tlvs[i + 1].tag.tagType == 0x17, 'X509: First tag was not in fact a UTC time');
        require(tlvs[i + 2].tag.tagType == 0x17, 'X509: Second tag was not in fact a UTC time');
        require(
            block.timestamp > timestampFromDate(tlvs[i + 1].value),
            'X509: It is too early to use this certificate'
        );
        uint256 expiry = timestampFromDate(tlvs[i + 2].value);
        require(block.timestamp < expiry, 'X509: This certificate has expired');
        return expiry;
    }

    function extractPublicKey(DecodedTlv[] memory tlvs) private view returns (RSAPublicKey memory) {
        // The public key data begins at the 5th SEQUENCE at depth 2
        uint256 i;
        uint256 j;
        for (i = 0; i < tlvs.length; i++) {
            if (tlvs[i].tag.tagType == 0x10 && tlvs[i].depth == 2) j++;
            if (j == 5) break;
        }
        // check we have RSA encryption. We use the keccak hash to check equality of the byte arrays
        require(
            keccak256(tlvs[i + 2].value) ==
                keccak256(abi.encodePacked(bytes9(0x2a864886f70d010101))),
            'X509: Only RSA ecryption keys are supported, the OID indicates a different key type'
        );
        bytes memory keyBytes = tlvs[i + 4].value;
        // extract the public key tlvs
        DecodedTlv[] memory keyTlvs = new DecodedTlv[](10);
        keyTlvs = this.parseDER(keyBytes, 1, 10);
        bytes memory modulus = keyTlvs[1].value;
        uint256 exponent = uint256(
            bytes32(keyTlvs[2].value) >> ((32 - keyTlvs[2].value.length) * 8)
        );
        
        return RSAPublicKey(modulus, exponent);
    }

    function extractSubjectKeyIdentifier(DecodedTlv[] memory tlvs) private view returns (bytes32) {
        // // The SKID begins after the Suject Key Identifier OID at depth 5
        uint256 i;
        for (i = 0; i < tlvs.length; i++) {
            if (tlvs[i].depth != 5) continue;
            if (
                bytes32(tlvs[i].value) ==
                bytes32((0x551d0e0000000000000000000000000000000000000000000000000000000000))
            ) break; // OID for the SKID
        }
        require(i < tlvs.length, 'X509: OID for Subject Key Identifier not found');
        bytes memory skidBytes = tlvs[i + 1].value;
        require(skidBytes.length < 33, 'X509: SKID is too long to encode as a bytes 32');
        DecodedTlv[] memory skidTlvs = new DecodedTlv[](1);
        skidTlvs = this.parseDER(skidBytes, 0, 2);
        bytes32 skid = bytes32(skidTlvs[0].value) >> ((32 - skidTlvs[0].length) * 8);
        return skid;
    }

    function extractAuthorityKeyIdentifier(
        DecodedTlv[] memory tlvs
    ) private view returns (bytes32) {
        // // The AKID begins after the Authority Key Identifier OID at depth 5
        uint256 i;
        for (i = 0; i < tlvs.length; i++) {
            if (tlvs[i].depth != 5) continue;
            if (
                bytes32(tlvs[i].value) ==
                bytes32((0x551d230000000000000000000000000000000000000000000000000000000000))
            ) break; // OID for the AKID
        }
        require(i < tlvs.length, 'X509: OID for Authority Key Identifier not found');
        bytes memory akidBytes = tlvs[i + 1].value;
        require(akidBytes.length < 33, 'X509: AKID is too long to encode as a bytes 32');
        DecodedTlv[] memory akidTlvs = new DecodedTlv[](3);
        akidTlvs = this.parseDER(akidBytes, 0, 2);
        bytes32 akid = bytes32(akidTlvs[1].value) >> ((32 - akidTlvs[1].value.length) * 8);
        return akid;
    }

    function checkKeyUsage(DecodedTlv[] memory tlvs, bytes1 _usageBitMask) private view {
        // // The key usage sequence begins after the Key Usage OID at depth 5
        uint256 i;
        for (i = 0; i < tlvs.length; i++) {
            if (tlvs[i].depth != 5) continue;
            if (
                bytes32(tlvs[i].value) ==
                bytes32((0x551d0f0000000000000000000000000000000000000000000000000000000000))
            ) break; // OID for keyUsage
        }
        require(i < tlvs.length, 'X509: OID for Key Usage not found');
        bytes memory usageBytes = tlvs[i + 1].value;
        // usageBytes could be an octet string containing a bit string, that needs further decoding to recover Key Usage flags
        // or it could be a boolean (code 0x01), indicating the criticality of the Key Usage (we ignore that and move on because we process Key Usage anyway)
        if (tlvs[i + 1].octets[0] == 0x01) usageBytes = tlvs[i + 2].value; // is it a boolean?
        DecodedTlv[] memory usageTlvs = new DecodedTlv[](1);
        usageTlvs = this.parseDER(usageBytes, 0, 1);
        require(usageTlvs[0].length == 2, 'X509: Key usage bytes must be of 2 bytes');
        // decoding of flags encoded as DER is strange. The first byte tells us how many bits to ignore in the second byte
        bytes1 usageFlags = (usageTlvs[0].value[1] >> uint8(usageTlvs[0].value[0])) <<
            uint8(usageTlvs[0].value[0]);
        // this is little endian and so must our mask be therefore
        require(
            (usageFlags & _usageBitMask) == _usageBitMask,
            'X509: Key usage is not as required'
        );
    }

    function checkExtendedKeyUsage(DecodedTlv[] memory tlvs, uint256 oidGroup) private view {
        // // The extended key usage sequence begins after the Extended Key Usage OID at depth 5
        uint256 i;
        for (i = 0; i < tlvs.length; i++) {
            if (tlvs[i].depth != 5) continue;
            if (
                bytes32(tlvs[i].value) ==
                bytes32((0x551d250000000000000000000000000000000000000000000000000000000000))
            ) break; // OID for extendedKeyUsage
        }
        require(i < tlvs.length, 'X509: OID for Extended Key Usage not found');
        bytes memory extendedUsageBytes = tlvs[i + 1].value;
        if (tlvs[i + 1].octets[0] == 0x01) extendedUsageBytes = tlvs[i + 2].value; // is it a boolean indicating criticality (we ignore that)?
        uint256 tlvLength = this.computeNumberOfTlvs(extendedUsageBytes, 0); // we cannot guess how long the list might be
        DecodedTlv[] memory extendedUsageTlvs = new DecodedTlv[](tlvLength);
        extendedUsageTlvs = this.parseDER(extendedUsageBytes, 0, tlvLength);
        // Now we need to loop through the extendedKeyUsageOIDs, and check we have every one of them in the cert
        for (uint256 j = 0; j < extendedKeyUsageOIDs[oidGroup].length; j++) {
            bool oidFound = false;
            for (uint256 k = 0; k < tlvLength; k++) {
                if (bytes32(extendedUsageTlvs[k].octets) == extendedKeyUsageOIDs[oidGroup][j]) {
                    oidFound = true;
                    break;
                }
            }
            require(oidFound, 'A required Extended Key Usage OID was not found');
        }
    }

    function checkCertificatePolicies(DecodedTlv[] memory tlvs, uint256 oidGroup) private view {
        // // The extended key usage sequence begins after the Extended Key Usage OID at depth 5
        uint256 i;
        for (i = 0; i < tlvs.length; i++) {
            if (tlvs[i].depth != 5) continue;
            if (
                bytes32(tlvs[i].value) ==
                bytes32((0x551d200000000000000000000000000000000000000000000000000000000000))
            ) break; // OID for certificate policies
        }
        require(i < tlvs.length, 'X509: OID for Certificate Policies not found');
        bytes memory extendedUsageBytes = tlvs[i + 1].value;
        if (tlvs[i + 1].octets[0] == 0x01) extendedUsageBytes = tlvs[i + 2].value; // is it a boolean indicating criticality (we ignore that)?
        uint256 tlvLength = this.computeNumberOfTlvs(extendedUsageBytes, 0); // we cannot guess how long the list might be
        DecodedTlv[] memory extendedUsageTlvs = new DecodedTlv[](tlvLength);
        extendedUsageTlvs = this.parseDER(extendedUsageBytes, 0, tlvLength);
        // certificate policies are, unfortunately not a simple oid but an octet string containing a sequence of sequences. The oids we want are in each sequence.
        // Thus extendedUsageTlvs is an array of sequences. We have to loop through it, collecting the first OID inside each.  We can ignore
        // the rest of the sequence which will be yet another sequence of policy qualifiers.  We don't care about those for this purpose.
        // We just need to ensure the policy exists.
        bytes32[] memory policyOIDs = new bytes32[](extendedUsageTlvs.length); // we don't know how many there are but there are definitely less than this
        uint256 count = 0;
        for (uint256 j = 0; j < extendedUsageTlvs.length; j++) {
            if (extendedUsageTlvs[j].depth == 2)
                policyOIDs[count++] = bytes32(extendedUsageTlvs[j].octets);
        }
        // Now we have an array containing the policy OIDs we need to loop through
        // the certificate policie OIDs, and check we have every one of them in the cert
        for (uint256 j = 0; j < certificatePoliciesOIDs[oidGroup].length; j++) {
            bool oidFound = false;
            for (uint256 k = 0; k < count; k++) {
                if (policyOIDs[k] == certificatePoliciesOIDs[oidGroup][j]) {
                    oidFound = true;
                    break;
                }
            }
            require(oidFound, 'A required Certificate Policy OID was not found');
        }
    }

    // function to check the signature over a message
    function checkSignature(
        bytes memory signature,
        bytes memory message,
        RSAPublicKey memory publicKey
    ) private view {
        bytes memory signatureDecrypt = modExp(signature, publicKey.exponent, publicKey.modulus);
        bytes memory messageHashFromSignature = validateSignatureAndExtractMessageHash(
            signatureDecrypt,
            5
        );
        // we use the keccak hash here as a low cost way to check equality of bytes data
        require(
            keccak256(messageHashFromSignature) == keccak256(abi.encode(sha256(message))) ||
                // if sha256 fails, try sha512.
                keccak256(messageHashFromSignature) == keccak256(this.sha512(message)),
            'X509: Signature is invalid'
        );
    }

    /**
    This function is the main one in the module. It calls all of the subsidiary functions necessary to validate an RSA cert
    If the validation is successful (and it's an endUserCert), it will add the sender to the allowlist contract, provided they
    are able to sign their ethereum address with the private key corresponding to the certificate.
     */
    function validateCertificate(
        CertificateArgs calldata args
    ) external {
        bytes calldata certificate = args.certificate;
        uint256 tlvLength = args.tlvLength;
        bytes calldata addressSignature = args.addressSignature;
        bool isEndUser = args.isEndUser;
        bool checkOnly = args.checkOnly;
        uint256 oidGroup = args.oidGroup;
        address addr = args.addr;
        // we can optionally pass in a address to allowlist. If we set address(0) then the function will allowlist msg.sender
        if (addr == address(0)) addr = msg.sender;
        DecodedTlv[] memory tlvs = new DecodedTlv[](tlvLength);
        // decode the DER encoded binary certificate data into an array of Tag-Length-Value structs
        tlvs = walkDerTree(certificate, 0, tlvLength);
        // extract the data from the certificate necessary for checking the signature and (hopefully) find the Authority public key in
        // the smart contract's list of trusted keys
        bytes32 authorityKeyIdentifier = extractAuthorityKeyIdentifier(tlvs);
        bytes memory signature = getSignature(tlvs, tlvLength);
        bytes memory message = getMessage(tlvs);
        RSAPublicKey memory publicKey = trustedPublicKeys[authorityKeyIdentifier];
        // validate the cert's signature and check that the cert is in date, and not revoked nor signed by a revoked cert,
        checkSignature(signature, message, publicKey);
        uint256 expiry = checkDates(tlvs);
        RSAPublicKey memory certificatePublicKey = extractPublicKey(tlvs);
        bytes32 subjectKeyIdentifier = extractSubjectKeyIdentifier(tlvs);
        require(
            !revokedKeys[subjectKeyIdentifier],
            'X509: The subject key of this certificate has been revoked'
        );
        require(
            !revokedKeys[authorityKeyIdentifier],
            'X509: The authority key of this certificates has been revoked'
        );
        // The certificate is valid and linked to a root we trust, so now we trust the certificate's public key too.
        // If this is not claimed to be an end user cert, we should check it's consistent with being an intermediate CA as that's the only other option
        if (!isEndUser) {
            // check that this certificate can sign certificates
            checkKeyUsage(tlvs, usageBitMaskIntermediate);
            // if yes, we conclude it's an intermediate CA from a root we trust and we add its public key to ones we trust (unless we're asked not to)
            if (!checkOnly) trustedPublicKeys[subjectKeyIdentifier] = certificatePublicKey;
            // we're done with the intermediate CA cert.
            return;
        }
        // If we're here, we should be dealing with an accetable end-user cert, let's check its key usage, extended key usage
        // and certificate policies all meet our requirements for a valid end user cert.
        checkKeyUsage(tlvs, usageBitMaskEndUser);
        checkExtendedKeyUsage(tlvs, oidGroup);
        checkCertificatePolicies(tlvs, oidGroup);
        // // If we get here, we're good so add this user to the allowlist data, unless we're only checking the certificate.
        if (!checkOnly) {
            // Ensure one certificate is tied to one address and vice versa
            require(
                keysByUser[addr] == bytes32(0) || keysByUser[addr] == subjectKeyIdentifier,
                'X509: This address is already linked to a different certificate'
            );
            require(
                addressByKey[subjectKeyIdentifier] == address(0) || addressByKey[subjectKeyIdentifier] == addr,
                'X509: This certificate is already linked to a different address'
            );
            // Before we finally add the address to the allowlist, just check that the sender of the allowlist request actually owns the
            // end user cert.  We do this by getting them to sign the Ethereum address they want allowlisted.
            checkSignature(addressSignature, abi.encodePacked(uint160(addr)), certificatePublicKey);
            expires[addr] = expiry;
            keysByUser[addr] = subjectKeyIdentifier;

            // RECORD reverse mapping for one-to-one binding
            addressByKey[subjectKeyIdentifier] = addr; 

            addUserToAllowlist(addr); // all checks have passed, so they are free to trade for now.
        }
    }

    // performs an ongoing X509 check (is the user still in the allowlist? Has the public key been revoked? Is the cert in date?)
    // We could also remove the user in this function, but that would burn more gas.
    function x509Check(address user) external view returns (bool) {
        if (
            !allowlisting ||
            (!revokedKeys[keysByUser[user]] &&
                expires[user] > block.timestamp &&
                isAllowlisted(user))
        ) return true;
        return false;
    }

    /** 
    This function allows a certificate to be revoked from a allowlisted address (or by the contract owner). This cannot be undone!
    It is useful if the private key is compromised.  The owner of the allowlisted address can revoke the certificate.
    Once this is done, they will lose their allowlisted status.
    @param _subjectKeyIdentifier - the subject key identifier for the certificate that is to be revoked.
    */
    function revokeKeyFromUserAddress(uint256 _subjectKeyIdentifier) external {
        bytes32 subjectKeyIdentifier = bytes32(_subjectKeyIdentifier);
        require(
            keysByUser[msg.sender] == subjectKeyIdentifier || msg.sender == owner,
            'X509: You are not the owner of this key'
        );
        revokedKeys[subjectKeyIdentifier] = true;
        delete trustedPublicKeys[subjectKeyIdentifier];

        // CLEANUP: remove bidirectional binding when revoked
        address addr = addressByKey[subjectKeyIdentifier];
        delete keysByUser[addr];
        delete addressByKey[subjectKeyIdentifier];
    }

    /** 
    This function allows a certifcate to be revoked from any address (or by the contract owner). this cannot be undone!
    It is useful if the private key is compromised.  The owner of the compromised private key can revoke the corresponding
    certificate by making a request from any Ethereum address by signing the address with the key which they wish to revoke
    Once this is done, they will lose their allowlisted status.
    @param _subjectKeyIdentifier - the subject key identifier for the certificate that is to be revoked.
    @param addressSignature - the signature over the address msg.sender, made using PKCS#1 padding.
    */
    function revokeKeyByAddressSignature(
        uint256 _subjectKeyIdentifier,
        bytes calldata addressSignature
    ) external {
        bytes32 subjectKeyIdentifier = bytes32(_subjectKeyIdentifier);
        RSAPublicKey memory certificatePublicKey = trustedPublicKeys[subjectKeyIdentifier];
        checkSignature(
            addressSignature,
            abi.encodePacked(uint160(msg.sender)),
            certificatePublicKey
        );
        revokedKeys[subjectKeyIdentifier] = true;
        delete trustedPublicKeys[subjectKeyIdentifier];

        // CLEANUP: remove bidirectional binding when revoked
        address addr = addressByKey[subjectKeyIdentifier];
        delete keysByUser[addr];
        delete addressByKey[subjectKeyIdentifier];
    }
}