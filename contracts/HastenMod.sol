pragma solidity ^0.8.0;

import "openzeppelin-solidity/contracts/proxy/utils/Initializable.sol";
import "openzeppelin-solidity/contracts/utils/Counters.sol";
import "openzeppelin-solidity/contracts/utils/cryptography/ECDSA.sol";
import "./HastenNFT.sol";
import "./HastenScript.sol";
import "./Utility.sol";

contract HastenMod is HastenNFT, Initializable {
    uint8 private constant mutableVersion = 0x1;

    using SafeERC20 for IERC20;

    mapping(uint256 => address) private _signers;

    using Counters for Counters.Counter;
    Counters.Counter private _tokenIds;

    // mapping for scripts storage
    mapping(uint256 => bytes) private _modData;
    mapping(uint256 => uint160) private _modRefs;

    HastenScript internal _scriptsLibrary;

    constructor(address libraryAddress, address daoAddress)
        ERC721("Hasten Mod v0 NFT ", "MOD")
        Ownable(address(0x7F7eF2F9D8B0106cE76F66940EF7fc0a3b23C974))
    {
        _scriptsLibrary = HastenScript(libraryAddress);
        _daoToken = IERC20(daoAddress);
    }

    function bootstrap() public payable initializer {
        // Ownable
        Ownable._bootstrap(address(0x7F7eF2F9D8B0106cE76F66940EF7fc0a3b23C974));
        // ERC721
        _name = "Hasten Mod v0 NFT";
        _symbol = "MOD";

        _scriptsLibrary = HastenScript(0xC0DE00ce4dc54b06BEa5EB116E4D6eF1e0A5Df49);
        _daoToken = IERC20(address(0));
    }

    function tokenURI(uint256 tokenId)
        public
        view
        virtual
        override
        returns (string memory)
    {
        require(
            _exists(tokenId),
            "HastenScript: URI query for nonexistent token"
        );

        bytes storage data = _modData[_modRefs[tokenId]];
        bytes memory ipfsCid = new bytes(32);
        for (uint256 i = 0; i < 32; i++) {
            ipfsCid[i] = data[i + 1]; // skip 1 byte, version number
        }
        return
            string(
                abi.encodePacked(
                    "ipfs://",
                    Utility.toBase58(
                        abi.encodePacked(uint8(0x12), uint8(0x20), ipfsCid)
                    )
                )
            );
    }

    function _scriptId(uint256 modId) private view returns (uint160) {
        uint160 res;
        bytes storage mutableData = _modData[_modRefs[modId]];
        {
            bytes memory scriptIdBytes = new bytes(20);
            for (uint256 i = 0; i < 20; i++) {
                scriptIdBytes[i] = mutableData[i + 33]; // skip 33 bytes, version number and ipfs cid
            }
            assembly {
                res := mload(add(scriptIdBytes, 20))
            }
        }
        return res;
    }

    function dataOf(uint256 modId)
        public
        view
        returns (bytes memory immutableData, bytes memory mutableData)
    {
        require(
            _exists(modId),
            "HastenScript: script query for nonexistent token"
        );

        mutableData = _modData[_modRefs[modId]];
        (immutableData, ) = _scriptsLibrary.dataOf(_scriptId(modId));
    }

    function setDelegate(uint256 scriptId, address delegate) public {
        require(
            msg.sender == _scriptsLibrary.ownerOf(scriptId),
            "HastenMod: Only the owner of the script can set signer delegate"
        );

        _signers[scriptId] = delegate;
    }

    function _upload(
        uint160 scriptId,
        bytes32 ipfsMetadata,
        bytes memory environment,
        uint256 amount
    ) internal {
        uint160 dataHash =
            uint160(
                uint256(keccak256(abi.encodePacked(scriptId, environment)))
            );

        // store only if not already present
        if (_modData[dataHash].length == 0) {
            _modData[dataHash] = abi.encodePacked(
                mutableVersion,
                ipfsMetadata,
                scriptId,
                environment
            );
        }

        for (uint256 i = 0; i < amount; i++) {
            _tokenIds.increment();
            uint256 newItemId = _tokenIds.current();

            _mint(msg.sender, newItemId);

            _modRefs[newItemId] = dataHash;
        }
    }

    function upload(
        uint160 scriptId,
        bytes32 ipfsMetadata,
        bytes memory environment,
        uint256 amount
    ) public {
        require(
            msg.sender == _scriptsLibrary.ownerOf(scriptId),
            "HastenMod: Only the owner of the script can upload mods"
        );

        _upload(scriptId, ipfsMetadata, environment, amount);
    }

    /*
        This is to allow any user to upload something as long as the owner of the script authorizes.
    */
    function uploadWithDelegateAuth(
        bytes memory signature,
        uint160 scriptId,
        bytes32 ipfsMetadata,
        bytes memory environment,
        uint256 amount
    ) public {
        bytes32 hash =
            ECDSA.toEthSignedMessageHash(
                keccak256(
                    abi.encodePacked(
                        msg.sender,
                        Utility.getChainId(),
                        scriptId,
                        ipfsMetadata,
                        environment,
                        amount
                    )
                )
            );
        require(
            _signers[scriptId] != address(0x0) &&
                _signers[scriptId] == ECDSA.recover(hash, signature),
            "HastenMod: Invalid signature"
        );

        _upload(scriptId, ipfsMetadata, environment, amount);
    }

    // reward the owner of the Script
    // limited to once per block for safety reasons
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 tokenId
    ) internal override {
        // ensure not a mint or burn
        if (
            to != address(0) &&
            from != address(0) &&
            address(_daoToken) != address(0)
        ) {
            address scriptOwner = _scriptsLibrary.ownerOf(_scriptId(tokenId));
            if (
                _rewardBlocks[scriptOwner] != block.number &&
                _daoToken.balanceOf(address(this)) > _reward
            ) {
                _daoToken.safeIncreaseAllowance(address(this), _reward);
                _daoToken.safeTransferFrom(address(this), scriptOwner, _reward);
                _rewardBlocks[scriptOwner] = block.number;
            }
        } else if (to == address(0)) {
            // burn, cleanup some memory
            // altho big storage is not cleared
            _modRefs[tokenId] = 0x0;
        }
    }

    function setScriptOwnerReward(uint256 amount) public onlyOwner {
        _reward = amount;
    }

    function getScriptOwnerReward() public view returns (uint256) {
        return _reward;
    }
}
