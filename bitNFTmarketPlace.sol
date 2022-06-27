// SPDX-License-Identifier: MIT
pragma solidity ^0.8.3;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

//Bit-NFT-Marketplace is a marketplace where you as a seller can list your erc721 tokens
//for sale either on cash and carry basis or on installmental basis.
//It is a platform where buyers can buy NFT in dribs and drabs.
//sellers sends their nft to the contract using its address and the tokenId where it is secured.
//At the end of the duration of the sale which is 40 days,the seller gets his ether while the buyer gets his NFT
//if the buyer defaults,he/she forfeits 10% of total ether sent(5% for the marketplace and 5% compensation to the seller)
//And the seller gets back his NFT while the buyer gets back his ether minus 10% of total.
//If it is an instant sale,the marketplace receive 5% of the NFT price otherwise all funds go to seller..

contract BitNFTMarketPlace is Ownable, IERC721Receiver {
    using Counters for Counters.Counter;
    //Deriving agreementId from Counters library
    Counters.Counter public agreementId;

    //All events to be emitted
    event NewNFTListed(
        address nftContractAddress,
        uint256 nftTokenId,
        address indexed seller,
        uint256 price
    );
    event NftBought(
        uint256 nftTokenId,
        address indexed seller,
        address indexed buyer,
        uint256 price
    );
    event BitBuy(
        address nftContractAddress,
        uint256 nftTokenId,
        address indexed seller,
        address buyer,
        uint256 price
    );
    event SellerClaim(uint256 nftTokenId, address indexed seller);
    event BuyerClaim(uint256 nftTokenId, address indexed buyer);
    event AgreementEnded(
        uint256 nftTokenId,
        address indexed buyer,
        bool saleEnded
    );
    event Received(address sender, uint256 amount, string message);

    //Modelling the agreement
    struct Agreements {
        address nftContractAddress;
        uint256 nftTokenId;
        address seller;
        uint256 agreementEndAt;
        bool saleEnded;
        uint256 price;
        bool onBit;
    }
    //map from agreementId => seller => totalPayForSeller
    mapping(uint256 => mapping(address => uint256)) public totalPayForSeller;

    mapping(uint256 => mapping(address => uint256)) bitsPerToken; //map amount paid in bit to each bit buyer for individual tokens

    //Map each agreement to its agreementId
    mapping(uint256 => Agreements) public agreements;

    modifier canListNFT(address _nftContractAddress, uint256 _nftTokenId) {
        require(
            IERC721(_nftContractAddress).ownerOf(_nftTokenId) == msg.sender,
            "You can only list only the NFT you own"
        );
        _;
    }
    modifier canBuyNow(uint256 _agreementId) {
        Agreements memory agreement = agreements[_agreementId];
        require(msg.sender != agreement.seller, "NFT owner cannot buy his NFT");
        require(
            msg.value == agreement.price,
            "Value sent must be equal to NFT price"
        );
        require(
            agreement.onBit == false,
            "A buyer has partly paid for this token"
        );
        _;
    }
    modifier canBuyInBits(uint256 _agreementId, address _seller) {
        Agreements memory agreement = agreements[_agreementId];
        require(msg.sender != agreement.seller, "NFT owner cannot buy his NFT");
        require(
            totalPayForSeller[_agreementId][agreement.seller] ==
                bitsPerToken[_agreementId][msg.sender],
            "This NFT has already been partly paid by another buyer"
        );
        require(
            block.timestamp < agreement.agreementEndAt,
            "agreement time has elapsed"
        );
        _;
    }
    modifier CanClaim(uint256 _agreementId) {
        Agreements memory agreement = agreements[_agreementId];
        require(
            bitsPerToken[_agreementId][msg.sender] <
                totalPayForSeller[_agreementId][agreement.seller],
            "total payment made"
        );
        require(
            agreement.saleEnded == true,
            "NFT Sale agreement has not ended yet"
        );
        require(
            block.timestamp >= agreement.agreementEndAt,
            "The agreement has not ended yet"
        );
        _;
    }

    modifier agreementEnded(uint256 _agreementId) {
        Agreements memory agreement = agreements[_agreementId];
        require(
            agreement.saleEnded == true &&
                (block.timestamp >= agreement.agreementEndAt),
            "agreement duration has not ended"
        );
        _;
    }

    //ListToken function help list NFT with its token contract address,tokenId and a price.
    //NFT can be bought between now and the next 40 days otherwise, it has to be re-listed
    function listToken(
        address _nftContractAddress,
        uint256 _nftTokenId,
        uint256 _price
    )
        public
        payable
        canListNFT(_nftContractAddress, _nftTokenId)
        returns (uint256 _Id)
    {
        IERC721(_nftContractAddress).safeTransferFrom(
            msg.sender,
            address(this),
            _nftTokenId
        );
        uint256 currentId = agreementId.current();
        agreementId.increment();
        Agreements storage agreement = agreements[currentId];
        // update each property of the agreement struct
        agreement.nftContractAddress = _nftContractAddress;
        agreement.nftTokenId = _nftTokenId;
        agreement.seller = msg.sender;
        agreement.saleEnded = false;
        agreement.price = _price;
        agreement.onBit = false;
        //The real agreement time is for 40 days but for testing purpose,we use 4 hours
        agreement.agreementEndAt = block.timestamp + (4 hours);
        emit NewNFTListed(_nftContractAddress, _nftTokenId, msg.sender, _price);
        return currentId;
    }

    //buyNow function is called when the buyer wishes to pay all the ether requested by the seller
    function buyNow(
        address _nftContractAddress,
        uint256 _agreementId,
        uint256 _nftTokenId,
        uint256 _price
    ) public payable canBuyNow(_agreementId) returns (bool) {
        Agreements storage agreement = agreements[_agreementId];
        //calculate commission
        uint256 commisionedValue = (_price * 95) / 100;
        uint256 contractValue = (_price * 5) / 100;
        //Prevent re-entrancy attack
        agreement.price = 0;
        agreement.saleEnded = true;
        agreement.seller = msg.sender;
        //ether  (amount= price minus contract commission) is sent from the contract to the seller
        (bool done, ) = payable(agreement.seller).call{value: commisionedValue}(
            ""
        );
        require(done, "Cannot send ether to the seller");
        //Send contract commission in form of ether to the smart contract owner
        (bool etherSent, ) = payable(Ownable.owner()).call{
            value: contractValue
        }("");
        require(etherSent, "Cannot send ether to the contract owner");
        //Smart contract sends nft to the buyer
        IERC721(_nftContractAddress).safeTransferFrom(
            address(this),
            msg.sender,
            _nftTokenId
        );
        agreement.onBit = false;
        emit NftBought(_nftTokenId, agreement.seller, msg.sender, _price);

        return true;
    }

    //BuyInBit function is called by buyers who intend to buy the NFT in installments.
    function buyInBit(
        address _nftContractAddress,
        uint256 _agreementId,
        uint256 _nftTokenId,
        address _seller
    )
        public
        payable
        canBuyInBits(_agreementId, _seller)
        returns (bool success)
    {
        Agreements memory agreement = agreements[_agreementId];
        agreement.seller = _seller;
        bitsPerToken[_agreementId][msg.sender] += msg.value;
        totalPayForSeller[_agreementId][_seller] += msg.value;
        //Prevent re-entrancy attack
        bitsPerToken[_agreementId][msg.sender] = 0;
        if (
            totalPayForSeller[_agreementId][_seller] + msg.value ==
            agreement.price &&
            bitsPerToken[_agreementId][msg.sender] >= agreement.price &&
            block.timestamp >= agreement.agreementEndAt
        ) {
            agreement.saleEnded = true;
            handlePayOut(_nftContractAddress, _agreementId, _nftTokenId);
            emit AgreementEnded(_nftTokenId, msg.sender, agreement.saleEnded);
        } else
            emit BitBuy(
                _nftContractAddress,
                _nftTokenId,
                agreement.seller,
                msg.sender,
                agreement.price
            );
        return (success);
    }

    function handlePayOut(
        address _nftContractAddress,
        uint256 _agreementId,
        uint256 _nftTokenId
    ) public payable {
        Agreements memory agreement = agreements[_agreementId];
        require(agreement.saleEnded, "Can only be called when sale is over");
        uint256 bal = bitsPerToken[_agreementId][msg.sender];
        uint256 commisionedValue = (bal * 95) / 100;
        uint256 contractValue = (bal * 5) / 100;
        //sends NFT to the buyer
        IERC721(_nftContractAddress).safeTransferFrom(
            address(this),
            msg.sender,
            _nftTokenId
        );
        agreement.saleEnded = true;
        //sends buyer's balance minus  contractValue to the seller
        (bool isSent, ) = payable(msg.sender).call{value: commisionedValue}("");
        require(isSent, "Cannot send ether to the seller");
        //sends buyer's balance minus commissionedValue to the seller
        (bool hasSent, ) = payable(agreement.seller).call{value: contractValue}(
            ""
        );
        require(hasSent, "Cannot send ether to the seller");
        emit AgreementEnded(_nftTokenId, agreement.seller, agreement.saleEnded);
    }

    //This function is used by the seller at the expiry of the installment agreement
    function sellerClaimNFT(
        address _nftContractAddress,
        uint256 _agreementId,
        uint256 _nftTokenId
    ) external CanClaim(_agreementId) {
        Agreements memory agreement = agreements[_agreementId];
        //calculate seller's compensation
        uint256 bal = bitsPerToken[_agreementId][msg.sender];
        uint256 compensationValue = (bal * 10) / 100;
        //Smart contract sends token to the seller
        IERC721(_nftContractAddress).transferFrom(
            address(this),
            msg.sender,
            _nftTokenId
        );
        //Prevent re-entrancy attack
        totalPayForSeller[_agreementId][msg.sender] = 0;
        agreement.saleEnded = true;
        //Smart contract sends compensation ether to the seller
        (bool compensationSent, ) = payable(msg.sender).call{
            value: compensationValue
        }("");
        require(compensationSent, "Cannot send ether to the seller");
        emit SellerClaim(_nftTokenId, msg.sender);
        emit AgreementEnded(_nftTokenId, msg.sender, agreement.saleEnded);
    }

    //BuyerClaimFund function is used by the buyer to claim his nft when he fails to pay all installment before the end of the agreement period
    function buyerClaimFund(uint256 _agreementId, uint256 _nftTokenId)
        external
        CanClaim(_agreementId)
        returns (bool success)
    {
        //calculate buyer's penalty
        uint256 bal = bitsPerToken[_agreementId][msg.sender];
        uint256 penaltyValue = (bal * 90) / 100;
        //Prevent re-entrancy attack
        bitsPerToken[_agreementId][msg.sender] = 0;
        //Smart contract sends ether to the buyer
        (bool penaltySent, ) = payable(msg.sender).call{value: penaltyValue}(
            ""
        );
        require(penaltySent, "Cannot send ether to the buyer");
        agreements[_agreementId].saleEnded = true;
        emit BuyerClaim(_nftTokenId, msg.sender);
        emit AgreementEnded(
            _nftTokenId,
            msg.sender,
            agreements[_agreementId].saleEnded
        );
        return (success);
    }

    //A view function that returns  Bit-NFT-MarketPlace Commission
    function getBitMktCommision(uint256 _agreementId)
        public
        view
        returns (uint256)
    {
        return (agreements[_agreementId].price * 5) / 100;
    }

    //A view function that returns the fund receivable by an NFT seller
    function getSellersFundReceivable(uint256 _agreementId)
        public
        view
        returns (uint256)
    {
        return (agreements[_agreementId].price * 95) / 100;
    }

    //receive function helps the smart contract to receive ether
    receive() external payable {
        emit Received(msg.sender, msg.value, "Fallback was called");
    }

    // onERC721Received function helps the smart contract to receive NFT
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
