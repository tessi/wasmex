use rustler::dynamic::TermType;

// PrintableTermType is a workaround for rustler::dynamic::TermType not having the Debug trait.
pub enum PrintableTermType {
    PrintTerm(TermType),
}

use std::fmt;
impl fmt::Debug for PrintableTermType {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        use PrintableTermType::PrintTerm;
        match self {
            PrintTerm(TermType::Atom) => write!(f, "Atom"),
            PrintTerm(TermType::Binary) => write!(f, "Binary"),
            PrintTerm(TermType::EmptyList) => write!(f, "EmptyList"),
            PrintTerm(TermType::Exception) => write!(f, "Exception"),
            PrintTerm(TermType::Fun) => write!(f, "Fun"),
            PrintTerm(TermType::List) => write!(f, "List"),
            PrintTerm(TermType::Map) => write!(f, "Map"),
            PrintTerm(TermType::Number) => write!(f, "Number"),
            PrintTerm(TermType::Pid) => write!(f, "Pid"),
            PrintTerm(TermType::Port) => write!(f, "Port"),
            PrintTerm(TermType::Ref) => write!(f, "Ref"),
            PrintTerm(TermType::Tuple) => write!(f, "Tuple"),
            PrintTerm(TermType::Unknown) => write!(f, "Unknown"),
        }
    }
}
