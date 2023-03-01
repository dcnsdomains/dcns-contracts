// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "./NamedRegistrar.sol";
import "./PriceOracle.sol";
import "./StringUtils.sol";
import "../resolver/Resolver.sol";
import "../registry/ReverseRegistrar.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract DcRegistrarController is Ownable {
    using StringUtils for *;
    uint constant public MIN_REGISTRATION_DURATION = 28 days;

    NamedRegistrar public base;
    PriceOracle public prices;
    ReverseRegistrar public reverseRegistrar;

    event NameRegistered(string name, bytes32 indexed label, address indexed owner, uint cost, uint expires);
    event NameRenewed(string name, bytes32 indexed label, uint cost, uint expires);
    event NewPriceOracle(address indexed oracle);

    constructor(
        NamedRegistrar _base,
        PriceOracle _prices,
        ReverseRegistrar _reverseRegistrar
    ) {
        base = _base;
        prices = _prices;
        reverseRegistrar = _reverseRegistrar;
    }

    function rentPrice(string memory name, uint duration) view public returns(uint) {
        return prices.price(name, duration);
    }

    function valid(string memory name) public pure returns(bool) {
        return name.strlen() >= 1;
    }

    function available(string memory name) public view returns(bool) {
        bytes32 label = keccak256(bytes(name));
        return valid(name) && base.available(uint256(label));
    }

    function register(
        string calldata name,
        address owner,
        uint duration
    ) external payable {
        registerWithConfig(name, owner, duration, address(0), address(0));
    }

    function registerWithConfig(
        string memory name,
        address owner,
        uint duration,
        address resolver,
        address addr
    ) public payable {
        uint cost = _consumeCommitment(name, duration);

        bytes32 label = keccak256(bytes(name));
        uint256 tokenId = uint256(label);

        uint expires;
        if(resolver != address(0)) {
            // Set this contract as the (temporary) owner, giving it
            // permission to set up the resolver.
            expires = base.register(tokenId, address(this), duration);

            // The nodehash of this label
            bytes32 nodehash = keccak256(abi.encodePacked(base.baseNode(), label));

            // Set the resolver
            base.registry().setResolver(nodehash, resolver);

            // Configure the resolver
            if (addr != address(0)) {
                Resolver(resolver).setAddr(nodehash, addr);
            }

            // Now transfer full ownership to the expeceted owner
            base.reclaim(tokenId, owner);
            base.transferFrom(address(this), owner, tokenId);
        } else {
            require(addr == address(0));
            expires = base.register(tokenId, owner, duration);
        }

        _setReverseRecord(name, owner);

        emit NameRegistered(name, label, owner, cost, expires);

        // Refund any extra payment
        if(msg.value > cost) {
            payable(msg.sender).transfer(msg.value - cost);
        }
    }

    function renew(string calldata name, uint duration) external payable {
        uint cost = rentPrice(name, duration);
        require(msg.value >= cost);

        bytes32 label = keccak256(bytes(name));
        uint expires = base.renew(uint256(label), duration);

        if(msg.value > cost) {
            payable(msg.sender).transfer(msg.value - cost);
        }

        emit NameRenewed(name, label, cost, expires);
    }

    function setPriceOracle(PriceOracle _prices) public onlyOwner {
        prices = _prices;
        emit NewPriceOracle(address(prices));
    }

    function withdraw() public onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }

    function _setReverseRecord(string memory name, address owner) internal {
        reverseRegistrar.setNameForAddr(
            msg.sender,
            owner,
            string.concat(name, ".dc")
        );
    }

    function _consumeCommitment(string memory name, uint duration) internal returns (uint256) {
        require(available(name));
        uint cost = rentPrice(name, duration);
        require(duration >= MIN_REGISTRATION_DURATION);
        require(msg.value >= cost);

        return cost;
    }
}