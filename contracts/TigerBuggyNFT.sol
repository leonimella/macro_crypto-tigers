// SPDX-License-Identifier: MIT

pragma solidity 0.8.2;

import "hardhat/console.sol";

/*
   NFT Contract along the lines of CryptoPunks. For the original see:
   https://github.com/larvalabs/cryptopunks/blob/master/contracts/CryptoPunksMarket.sol

   Incorporates some ideas and code from the OpenZeppelin ERC721Enumerable contract:

   https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC721/extensions/ERC721Enumerable.sol
   https://docs.openzeppelin.com/contracts/2.x/api/token/erc721#ERC721Enumerable
*/
contract TigerBuggyNFT {

    // how many unique tiger tokens exist
    uint public constant totalSupply = 100;

    // percentage of sale price taken as royalty for the contract
    uint public constant contractRoyaltyPercentage = 1;

    // percentage of sale price taken as royalty for the artist
    uint public constant artistRoyaltyPercentage = 5;

    // address that deployed this contract
    address private deployer;

    // address of the artist, initial owner of all tiger tokens, recipient of artist's fees
    address private artist;

    // initial sale price for all tokens
    uint private startingPrice;

    // mapping from token ID to owner address
    mapping(uint => address) private tigerOwners;

    // mapping from owner address to number of tokens they own
    mapping(address => uint) private balanceOf;

    // mapping from owner address to list of IDs of all tokens they own
    mapping(address => mapping(uint256 => uint256)) private tigersOwnedBy;

    // mapping from token ID to its index position in the owner's tokens list
    mapping(uint256 => uint256) private tigersOwnedByIndex;

    // tigers currently up for sale
    struct SaleOffer {
        bool isForSale;
        address seller;
        uint price;
    }
    mapping (uint => SaleOffer) public tigersForSale;

    // ether held by the contract on behalf of addresses that have interacted with it
    mapping (address => uint) public pendingWithdrawals;

    event TigerForSale(address indexed seller, uint indexed tigerId, uint price);
    event TigerSold(address indexed seller, address indexed buyer, uint indexed tigerId, uint price);
    event TigerWithdrawnFromSale(address indexed seller, uint indexed tigerId);

    // create the contract, artist is set here and never changes subsequently
    constructor(address _artist, uint _startingPrice) {
        require(_artist != address(0));
        _init_(_artist, msg.sender, _startingPrice);
    }

    // initialize the contract state
    function _init_(address _artist, address _deployer, uint _startingPrice) public {
        artist = _artist;
        deployer = _deployer;
        startingPrice = _startingPrice;
    }

    // allow anyone to see if a tiger is for sale and, if so, for how much
    function isForSale(uint tigerId) external view returns (bool, uint) {
        require(tigerId < totalSupply, "index out of range");
        SaleOffer memory saleOffer = getSaleInfo(tigerId);
        if (saleOffer.isForSale) {
            return(true, saleOffer.price);
        }
        return (false, 0);
    }

    // tokens which have never been sold are for sale at the starting price,
    // all others are not unless the owner puts them up for sale
    function getSaleInfo(uint tigerId) private view returns (SaleOffer memory saleOffer) {
        if (tigerOwners[tigerId] == address(0)) {
            saleOffer = SaleOffer(true, artist, startingPrice);
        } else {
            saleOffer = tigersForSale[tigerId];
        }
    }

    // get the number of tigers owned by the address
    function getBalance(address owner) public view returns (uint) {
        return balanceOf[owner];
    }

    // get the current owner of a token, unsold tokens belong to the artist
    function getOwner(uint tigerId) public view returns (address) {
        require(tigerId < totalSupply, "index out of range");
        address owner = tigerOwners[tigerId];
        if (owner == address(0)) {
            owner = artist;
        }
        return owner;
    }

    // get the ID of the index'th tiger belonging to owner (who must own at least index + 1 tigers)
    function tigerByOwnerAndIndex(address owner, uint index) public view returns (uint) {
        require(index < balanceOf[owner], "owner doesn't have that many tigers");
        return tigersOwnedBy[owner][index];
    }

    // allow the current owner to put a tiger token up for sale
    function putUpForSale(uint tigerId, uint minSalePriceInWei) external {
        require(tigerId < totalSupply, "index out of range");
        require(getOwner(tigerId) == msg.sender, "not owner");
        require(minSalePriceInWei > 0, "sale price can't be zero");
        tigersForSale[tigerId] = SaleOffer(true, msg.sender, minSalePriceInWei);
        emit TigerForSale(msg.sender, tigerId, minSalePriceInWei);
    }

    // allow the current owner to withdraw a tiger token from sale
    function withdrawFromSale(uint tigerId) external {
        require(tigerId < totalSupply, "index out of range");
        require(getOwner(tigerId) == msg.sender, "not owner");
        tigersForSale[tigerId] = SaleOffer(false, address(0), 0);
        emit TigerWithdrawnFromSale(msg.sender, tigerId);
    }

    // update ownership tracking for newly acquired tiger token
    function updateTigerOwnership(uint tigerId, address newOwner, address previousOwner) private {
        bool firstSale = tigerOwners[tigerId] == address(0);
        tigerOwners[tigerId] = newOwner;
        balanceOf[newOwner]++;
        if (!firstSale) {
            balanceOf[previousOwner]--;

            // To prevent a gap in previousOwner's tokens array
            // we store the last token in the index of the token to delete, and
            // then delete the last slot (swap and pop).

            uint lastTokenIndex = balanceOf[previousOwner];
            uint tokenIndex = tigersOwnedByIndex[tigerId];

            // When the token to delete is the last token, the swap operation is unnecessary
            if (tokenIndex != lastTokenIndex) {
                uint lastTokenId = tigersOwnedBy[previousOwner][lastTokenIndex];
                // Move the last token to the slot of the to-delete token
                tigersOwnedBy[previousOwner][tokenIndex] = lastTokenId;
                // Update the moved token's index
                tigersOwnedByIndex[lastTokenId] = tokenIndex;
            }

            delete tigersOwnedBy[previousOwner][lastTokenIndex];
        }
        uint newIndex = balanceOf[newOwner] - 1;
        tigersOwnedBy[newOwner][newIndex] = tigerId;
        tigersOwnedByIndex[tigerId] = newIndex;
        delete tigersForSale[tigerId];
    }

    // allow someone to buy a tiger offered for sale
    function buyTiger(uint tigerId) external payable {
        require(tigerId < totalSupply, "index out of range");
        SaleOffer memory saleOffer = getSaleInfo(tigerId);
        require(saleOffer.isForSale,"not for sale");
        (uint contractRoyalty, uint artistRoyalty) = calculateRoyalties(msg.value);
        pendingWithdrawals[deployer] += contractRoyalty;
        pendingWithdrawals[artist] += artistRoyalty;
        pendingWithdrawals[saleOffer.seller] += msg.value - (contractRoyalty + artistRoyalty);
        updateTigerOwnership(tigerId, msg.sender, saleOffer.seller);
        emit TigerSold(saleOffer.seller, msg.sender, tigerId, saleOffer.price);
    }

    // calculate the contract and artist royalties due on the sale amount
    function calculateRoyalties(uint amount) private pure returns (uint contractRoyalty, uint artistRoyalty) {
        contractRoyalty = (amount / 100) * contractRoyaltyPercentage;
        artistRoyalty = (amount / 100) * artistRoyaltyPercentage;

        return (contractRoyalty, artistRoyalty);
    }

    // allow participant to withdraw accumulated funds
    function withdrawFunds() external {
        uint balance = pendingWithdrawals[msg.sender];
        pendingWithdrawals[msg.sender] = 0;

        payable(msg.sender).transfer(balance);
    }


}
