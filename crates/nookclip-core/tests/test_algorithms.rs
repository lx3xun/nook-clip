use nookclip_core::algorithms::analyze_content;

#[test]
fn test_analyze_content_email_and_url_detection() {
    let email_sample = "Contact us at support@nook.app for help";
    let res1 = analyze_content(email_sample);
    assert!(res1.has_email);
    assert!(!res1.is_url);

    let url_sample = "https://github.com/lx3xun/nook";
    let res2 = analyze_content(url_sample);
    assert!(!res2.has_email);
    assert!(res2.is_url);

    let code_sample = "fn main() { println!(\"hello\"); }";
    let res3 = analyze_content(code_sample);
    assert!(!res3.has_email);
    assert!(!res3.is_url);
    assert_eq!(res3.detected_language, Some("rust".to_string()));
}
