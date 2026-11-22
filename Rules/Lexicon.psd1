# Rules/Lexicon.psd1 - the document category lexicon (v3.0 Phase 2.6).
#
# Weighted token scoring for DOCUMENTS (pdf/docx/txt/md/csv/...). A file's stem,
# its metadata (title/creator) and its first 2 KB text snippet are matched against
# the entries below; the score becomes the Decision's confidence.
#   Filename tokens  count at 1.2x weight each (the strongest single signal)
#   Metadata tokens  count at 1.0x weight each (title / creator)
#   Content tokens   count at 0.6x weight each (first 2 KB of text)
# confidence = matched / (matched + Confidence.Divider)
# Entries are evaluated in order; the best match wins, ties break by list order
# (deterministic). Extend freely - multilingual tokens are welcome (Swahili and
# Kenyan administrative terms are included as examples).

@{
    Version = '1.0'

    Multiplier = @{ Filename = 1.2; Metadata = 1.0; Content = 0.6 }

    Confidence = @{ Divider = 1.5 }     # matched/(matched+1.5): 3.5 -> 0.70, 1.0 -> 0.40

    Entries = @(
        @{ Subtype = 'Finance\Invoices'
           Filename = @('invoice','ankara')
           Content  = @('invoice','invoice number','invoice no','amount due','total due','payment due','due date','bill to','tax invoice','vat amount') }

        @{ Subtype = 'Finance\Receipts'
           Filename = @('receipt','risiti')
           Content  = @('receipt','received from','amount received','paid by','cash received','mpesa','m-pesa','transaction id','thank you for your payment') }

        @{ Subtype = 'Finance\Statements'
           Filename = @('statement','bank statement','mpesa statement','m-pesa statement')
           Content  = @('statement of account','account statement','opening balance','closing balance','balance brought forward','transaction history','debit','credit') }

        @{ Subtype = 'Finance\Tax'
           Filename = @('tax','paye','kra','vat return','nhif','nssf','withholding','it1','p9 form')
           Content  = @('kenya revenue authority','kra','pin number','tax payer','paye','vat','withholding tax','tax return','assessment','nhif','nssf','itax') }

        @{ Subtype = 'Legal-Identity'
           Filename = @('contract','agreement','certificate','passport','identity','id scan','deed','licence','license','permit','lease')
           Content  = @('this agreement','the parties','witnesseth','hereby','terms and conditions','certificate of','passport number','identity card','national id','date of birth','signature','in witness whereof') }

        @{ Subtype = 'Education'
           Filename = @('thesis','dissertation','syllabus','assignment','coursework','exam','lecture','timetable','transcript')
           Content  = @('university','school','college','campus','faculty','department of','course outline','learning outcomes','semester','assignment','examination','thesis','references','bibliography','chapter one','introduction') }

        @{ Subtype = 'Work'
           Filename = @('proposal','minutes','memo','report','brief','agenda','meeting')
           Content  = @('meeting minutes','action items','agenda','attendees','proposal','project plan','deliverables','milestones','q1','q2','stakeholders','follow up','as discussed') }

        @{ Subtype = 'Manuals'
           Filename = @('manual','handbook','user guide','quick start','instructions','guide')
           Content  = @('user manual','quick start','installation guide','step 1','step 2','troubleshooting','features','specifications','warranty','safety instructions','table of contents','getting started') }

        @{ Subtype = 'Books'
           Filename = @('book','novel','textbook','anthology')
           Content  = @('chapter','copyright','published by','isbn','all rights reserved','preface','foreword','contents','epilogue','prologue') }
    )
}
