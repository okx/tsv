// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Gregorian date math shared by trade-day and monthly report accounting.
library TradeDayLib {
    error InvalidPeriod();

    function dateToOrdinal(uint32 date) internal pure returns (uint256 ordinal) {
        uint256 year = date / 10_000;
        uint256 month = (date / 100) % 100;
        uint256 day = date % 100;
        if (year < 1970 || year > 9999 || month == 0 || month > 12 || day == 0) revert InvalidPeriod();
        uint256 daysInMonth = _daysInMonth(year, month);
        if (day > daysInMonth) revert InvalidPeriod();
        uint256 adjustedYear = month <= 2 ? year - 1 : year;
        uint256 era = adjustedYear / 400;
        uint256 yearOfEra = adjustedYear - era * 400;
        uint256 adjustedMonth = month > 2 ? month - 3 : month + 9;
        uint256 dayOfYear = (153 * adjustedMonth + 2) / 5 + day - 1;
        uint256 dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear;
        ordinal = era * 146_097 + dayOfEra - 719_468;
    }

    function ordinalToDate(uint256 ordinal) internal pure returns (uint32) {
        uint256 z = ordinal + 719_468;
        uint256 era = z / 146_097;
        uint256 dayOfEra = z - era * 146_097;
        uint256 yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365;
        uint256 year = yearOfEra + era * 400;
        uint256 dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100);
        uint256 monthPrime = (5 * dayOfYear + 2) / 153;
        uint256 day = dayOfYear - (153 * monthPrime + 2) / 5 + 1;
        uint256 month = monthPrime < 10 ? monthPrime + 3 : monthPrime - 9;
        year += month <= 2 ? 1 : 0;
        if (year < 1970 || year > 9999) revert InvalidPeriod();
        return uint32(year * 10_000 + month * 100 + day);
    }

    function previousMonth(uint32 day) internal pure returns (uint32) {
        uint256 year = day / 10_000;
        uint256 month = (day / 100) % 100;
        dateToOrdinal(day);
        if (month == 1) return uint32((year - 1) * 100 + 12);
        return uint32(year * 100 + month - 1);
    }

    function validMonth(uint32 monthId) internal pure returns (bool) {
        return monthId / 100 >= 1970 && monthId / 100 <= 9999 && monthId % 100 >= 1 && monthId % 100 <= 12;
    }

    function timestamp64(uint256 timestamp) internal pure returns (uint64) {
        if (timestamp > type(uint64).max) revert InvalidPeriod();
        return uint64(timestamp);
    }

    function _daysInMonth(uint256 year, uint256 month) private pure returns (uint256) {
        if (month == 2) return _isLeapYear(year) ? 29 : 28;
        if (month == 4 || month == 6 || month == 9 || month == 11) return 30;
        return 31;
    }

    function _isLeapYear(uint256 year) private pure returns (bool) {
        return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
    }
}
